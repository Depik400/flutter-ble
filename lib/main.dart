import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart' as ble;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final appDir = await getApplicationDocumentsDirectory();
  Hive.init(appDir.path);
  await Hive.openBox('chat_history');

  runApp(const BLEChatApp());
}

class BLEChatApp extends StatelessWidget {
  const BLEChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Chat',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF17212B),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2AABEE),
          brightness: Brightness.dark,
        ),
      ),
      home: const ChatScreen(),
    );
  }
}

// ---------- Экран чата ----------
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final BLEManager _bleManager = BLEManager();
  ble.Peripheral? _selectedDevice;

  @override
  void initState() {
    super.initState();
    _bleManager.init();
  }

  @override
  void dispose() {
    _bleManager.dispose();
    super.dispose();
  }

  void _onSelectDevice(ble.Peripheral device) {
    setState(() => _selectedDevice = device);
    _bleManager.connectToDevice(device);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 280,
            child: DeviceListPanel(
              bleManager: _bleManager,
              selectedDevice: _selectedDevice,
              onSelect: _onSelectDevice,
            ),
          ),
          const VerticalDivider(width: 1, color: Color(0xFF242F3D)),
          Expanded(
            child: _selectedDevice == null
                ? const Center(
                    child: Text(
                      'Выберите устройство слева',
                      style: TextStyle(fontSize: 16, color: Color(0xFF8E99A4)),
                    ),
                  )
                : ChatPanel(
                    bleManager: _bleManager, device: _selectedDevice!),
          ),
        ],
      ),
    );
  }
}

// ---------- Менеджер BLE (совместим с bluetooth_low_energy 6.2.1) ----------
class BLEManager extends ChangeNotifier {
  static const String serviceUuid = '12345678-1234-1234-1234-123456789abc';
  static const String rxCharUuid = '12345678-1234-1234-1234-123456789ab1'; // notify (для нас)
  static const String txCharUuid = '12345678-1234-1234-1234-123456789ab2'; // write (от нас)

  final ble.CentralManager _central = ble.CentralManager();
  final ble.PeripheralManager _peripheral = ble.PeripheralManager();

  final List<ble.DiscoveredEventArgs> _scanResults = [];
  List<ble.DiscoveredEventArgs> get scanResults => _scanResults;

  ble.Peripheral? _connectedDevice;
  ble.Peripheral? get connectedDevice => _connectedDevice;

  ble.GATTCharacteristic? _remoteRxChar;

  AppConnectionState _connectionState = AppConnectionState.disconnected;
  AppConnectionState get connectionState => _connectionState;

  late Box<String> _messageBox;
  StreamSubscription? _scanSub;
  StreamSubscription? _peripheralSub;

  BLEManager() {
    _messageBox = Hive.box('chat_history');
  }

  Future<void> init() async {
    await _startPeripheral();
    await _startScanning();
  }

  // ---------- Сообщения ----------
  List<Message> getMessages(String deviceId) {
    final raw = _messageBox.get(deviceId);
    if (raw == null) return [];
    try {
      final List<dynamic> list = json.decode(raw);
      return list.map((e) => Message.fromMap(e)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveMessages(String deviceId, List<Message> messages) async {
    final encoded = json.encode(messages.map((m) => m.toMap()).toList());
    await _messageBox.put(deviceId, encoded);
    notifyListeners();
  }

  void _addMessage(String deviceId, Message message) {
    final messages = List<Message>.from(getMessages(deviceId));
    messages.add(message);
    _saveMessages(deviceId, messages);
  }

  // ---------- Периферийная роль ----------
  Future<void> _startPeripheral() async {
    // Создаём сервис с двумя характеристиками
    final localService = ble.GATTService(
      uuid: ble.UUID.fromString(serviceUuid),
      isPrimary: true,
      includedServices: [],
      characteristics: [
        ble.GATTCharacteristic.mutable(
          uuid: ble.UUID.fromString(rxCharUuid),
          properties: [ble.GATTCharacteristicProperty.notify],
          permissions: [ble.GATTCharacteristicPermission.read],
          descriptors: [],
        ),
        ble.GATTCharacteristic.mutable(
          uuid: ble.UUID.fromString(txCharUuid),
          properties: [ble.GATTCharacteristicProperty.writeWithoutResponse],
          permissions: [ble.GATTCharacteristicPermission.write],
          descriptors: [],
        ),
      ],
    );

    await _peripheral.addService(localService);

    // Запускаем рекламу
    final advertiseData = ble.Advertisement(
      name: 'BLE Chat',
      serviceUUIDs: [ble.UUID.fromString(serviceUuid)],
    );
    await _peripheral.startAdvertising(advertiseData);

    // Обработчик запросов на запись в характеристику (когда нам присылают сообщение)
    _peripheralSub =
        _peripheral.characteristicWriteRequested.listen((event) async {
      if (event.characteristic.uuid == ble.UUID.fromString(txCharUuid)) {
        final text = utf8.decode(event.request.value);
        final senderId = event.central.uuid.toString();
        _addMessage(senderId, Message(text: text, isMe: false));
        await _peripheral.respondWriteRequest(event.request);
      } else {
        await _peripheral.respondWriteRequestWithError(
          event.request,
          error: ble.GATTError.requestNotSupported,
        );
      }
    });
  }

  // ---------- Сканирование (центральная роль) ----------
  Future<void> _startScanning() async {
    _scanSub = _central.discovered.listen((result) {
      final exists = _scanResults
          .any((r) => r.peripheral.uuid == result.peripheral.uuid);
      if (!exists) {
        _scanResults.add(result);
        notifyListeners();
      }
    });

    await _central.startDiscovery(
      serviceUUIDs: [ble.UUID.fromString(serviceUuid)],
    );
  }

  void rescan() async {
    await _central.stopDiscovery();
    _scanResults.clear();
    notifyListeners();
    await _startScanning();
  }

  // ---------- Подключение к удалённому устройству ----------
  Future<void> connectToDevice(ble.Peripheral device) async {
    await _disconnectCurrent();

    _connectedDevice = device;
    _connectionState = AppConnectionState.connecting;
    notifyListeners();

    _central.characteristicNotified.listen((event) {
      if (event.peripheral.uuid == device.uuid &&
          event.characteristic.uuid == ble.UUID.fromString(rxCharUuid)) {
        final text = utf8.decode(event.value);
        _addMessage(device.uuid.toString(),
            Message(text: text, isMe: false));
      }
    });

    _central.connectionStateChanged.listen((state) {
      if (state.peripheral.uuid == device.uuid &&
          state.state == ble.ConnectionState.disconnected) {
        _connectionState = AppConnectionState.disconnected;
        notifyListeners();
        _attemptReconnect(device);
      }
    });

    try {
      await _central.connect(device);
      final services = await _central.discoverGATT(device);
      _connectionState = AppConnectionState.connected;
      notifyListeners();

      for (final service in services) {
        if (service.uuid == ble.UUID.fromString(serviceUuid)) {
          for (final char in service.characteristics) {
            if (char.uuid == ble.UUID.fromString(rxCharUuid)) {
              await _central.setCharacteristicNotifyState(
                device,
                char,
                state: true,
              );
            } else if (char.uuid == ble.UUID.fromString(txCharUuid)) {
              _remoteRxChar = char;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Connection failed: $e');
      _connectionState = AppConnectionState.disconnected;
      notifyListeners();
      _attemptReconnect(device);
    }
  }

  void _attemptReconnect(ble.Peripheral device) {
    int attempts = 0;
    const maxAttempts = 10;
    Future.doWhile(() async {
      if (_connectedDevice?.uuid != device.uuid) return false;
      if (_connectionState == AppConnectionState.connected) return false;
      if (attempts >= maxAttempts) {
        debugPrint('Reconnect attempts exhausted');
        return false;
      }
      attempts++;
      debugPrint('Reconnecting attempt $attempts to ${device.uuid}...');
      await Future.delayed(const Duration(seconds: 5));
      try {
        await _central.connect(device);
        final services = await _central.discoverGATT(device);
        for (final service in services) {
          if (service.uuid == ble.UUID.fromString(serviceUuid)) {
            for (final char in service.characteristics) {
              if (char.uuid == ble.UUID.fromString(rxCharUuid)) {
                await _central.setCharacteristicNotifyState(
                  device,
                  char,
                  state: true,
                );
              }
            }
          }
        }
        _connectionState = AppConnectionState.connected;
        notifyListeners();
        return false;
      } catch (e) {
        debugPrint('Reconnect failed: $e');
        return true;
      }
    });
  }

  Future<void> manualReconnect() async {
    if (_connectedDevice == null) return;
    await connectToDevice(_connectedDevice!);
  }

  Future<void> _disconnectCurrent() async {
    if (_connectedDevice != null) {
      try {
        await _central.disconnect(_connectedDevice!);
      } catch (_) {}
      _connectedDevice = null;
    }
  }

  // ---------- Отправка сообщения ----------
  Future<void> sendMessage(String deviceId, String text) async {
    if (_remoteRxChar == null || _connectedDevice == null) return;
    final msg = Message(text: text, isMe: true);
    _addMessage(deviceId, msg);
    try {
      await _central.writeCharacteristic(
        _connectedDevice!,
        _remoteRxChar!,
        value: Uint8List.fromList(utf8.encode(text)),
        type: ble.GATTCharacteristicWriteType.withoutResponse,
      );
    } catch (e) {
      debugPrint('Write error: $e');
    }
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _peripheralSub?.cancel();
    _central.stopDiscovery();
    _peripheral.stopAdvertising();
    _disconnectCurrent();
    super.dispose();
  }
}

// ---------- Модель сообщения ----------
class Message {
  final String text;
  final bool isMe;

  Message({required this.text, required this.isMe});

  Map<String, dynamic> toMap() => {'text': text, 'isMe': isMe};
  factory Message.fromMap(Map<dynamic, dynamic> map) =>
      Message(text: map['text'], isMe: map['isMe'] as bool);
}

enum AppConnectionState { disconnected, connecting, connected }

// ---------- Сайдбар устройств ----------
class DeviceListPanel extends StatelessWidget {
  final BLEManager bleManager;
  final ble.Peripheral? selectedDevice;
  final void Function(ble.Peripheral) onSelect;

  const DeviceListPanel({
    super.key,
    required this.bleManager,
    required this.selectedDevice,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF17212B),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Устройства',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ),
          const Divider(height: 1, color: Color(0xFF242F3D)),
          Expanded(
            child: ListenableBuilder(
              listenable: bleManager,
              builder: (context, _) {
                final results = bleManager.scanResults;
                if (results.isEmpty) {
                  return const Center(
                    child: Text('Нет устройств',
                        style: TextStyle(color: Color(0xFF8E99A4))),
                  );
                }
                return ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (context, index) {
                    final result = results[index];
                    final device = result.peripheral;
                    final deviceName = result.advertisement.name?.isNotEmpty == true
                        ? result.advertisement.name!
                        : device.uuid.toString();
                    final isSelected = selectedDevice?.uuid == device.uuid;
                    final isConnected =
                        bleManager.connectedDevice?.uuid == device.uuid;
                    final state = isConnected
                        ? bleManager.connectionState
                        : AppConnectionState.disconnected;

                    IconData icon;
                    Color iconColor;
                    String stateText;
                    switch (state) {
                      case AppConnectionState.connected:
                        icon = Icons.bluetooth_connected;
                        iconColor = const Color(0xFF2AABEE);
                        stateText = 'подключено';
                        break;
                      case AppConnectionState.connecting:
                        icon = Icons.bluetooth_searching;
                        iconColor = Colors.orangeAccent;
                        stateText = 'подключение…';
                        break;
                      case AppConnectionState.disconnected:
                        icon = Icons.bluetooth_disabled;
                        iconColor = const Color(0xFF8E99A4);
                        stateText = 'не подключено';
                        break;
                    }

                    return ListTile(
                      leading: Icon(icon, color: iconColor),
                      title: Text(
                        deviceName,
                        style: TextStyle(
                          color: isConnected
                              ? Colors.white
                              : const Color(0xFF8E99A4),
                          fontWeight: isConnected
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        stateText,
                        style: TextStyle(fontSize: 12, color: iconColor),
                      ),
                      selected: isSelected,
                      selectedTileColor: const Color(0xFF2B5278),
                      onTap: () => onSelect(device),
                    );
                  },
                );
              },
            ),
          ),
          const Divider(height: 1, color: Color(0xFF242F3D)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: ElevatedButton.icon(
              onPressed: bleManager.rescan,
              icon: const Icon(Icons.refresh),
              label: const Text('Сканировать'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Панель чата ----------
class ChatPanel extends StatefulWidget {
  final BLEManager bleManager;
  final ble.Peripheral device;

  const ChatPanel({super.key, required this.bleManager, required this.device});

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  Widget build(BuildContext context) {
    final deviceId = widget.device.uuid.toString();
    final messages = widget.bleManager.getMessages(deviceId);
    final isConnected =
        widget.bleManager.connectionState == AppConnectionState.connected;

    return Container(
      color: const Color(0xFF0E1621),
      child: Column(
        children: [
          // Заголовок чата
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            color: const Color(0xFF17212B),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor:
                      isConnected ? const Color(0xFF2AABEE) : Colors.grey,
                  child: Icon(Icons.person, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        deviceId,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        isConnected ? 'в сети' : 'не в сети',
                        style: TextStyle(
                          fontSize: 12,
                          color: isConnected
                              ? const Color(0xFF2AABEE)
                              : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!isConnected)
                  IconButton(
                    icon: const Icon(Icons.wifi_find,
                        color: Colors.orangeAccent),
                    onPressed: () => widget.bleManager.manualReconnect(),
                    tooltip: 'Переподключиться',
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF242F3D)),
          // Сообщения
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Text('Нет сообщений',
                        style: TextStyle(color: Color(0xFF8E99A4))),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                        vertical: 8, horizontal: 16),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      return _MessageBubble(message: msg);
                    },
                  ),
          ),
          // Поле ввода
          Container(
            color: const Color(0xFF17212B),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    enabled: isConnected,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText:
                          isConnected ? 'Сообщение...' : 'Нет соединения',
                      hintStyle: const TextStyle(color: Color(0xFF8E99A4)),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: const Color(0xFF242F3D),
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 16),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor:
                      isConnected ? const Color(0xFF2AABEE) : Colors.grey,
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white),
                    onPressed: isConnected
                        ? () {
                            final text = _textController.text.trim();
                            if (text.isNotEmpty) {
                              widget.bleManager.sendMessage(deviceId, text);
                              _textController.clear();
                              _scrollController.animateTo(
                                _scrollController.position.maxScrollExtent,
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOut,
                              );
                            }
                          }
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Пузырёк сообщения ----------
class _MessageBubble extends StatelessWidget {
  final Message message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isMe = message.isMe;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFF2AABEE) : const Color(0xFF182533),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          message.text,
          style: const TextStyle(fontSize: 15, color: Colors.white),
        ),
      ),
    );
  }
}