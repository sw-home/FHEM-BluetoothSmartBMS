import socket
import threading
import gatt
import json
import sys

bind_ip = '0.0.0.0'

class AnyDevice(gatt.Device):
    def connect(self):
        print("[%s] Connecting" % (self.mac_address))
        self.event = threading.Event()
        super().connect()

    def connect_succeeded(self):
        super().connect_succeeded()
        print("[%s] Connected" % (self.mac_address))

    def connect_failed(self, error):
        super().connect_failed(error)
        print("[%s] Connection failed: %s" % (self.mac_address, str(error)))

    def disconnect_succeeded(self):
        super().disconnect_succeeded()
        print("[%s] Disconnected" % (self.mac_address))

    def services_resolved(self):
        super().services_resolved()

        device_information_service = next(
            s for s in self.services
            if s.uuid == '0000ff00-0000-1000-8000-00805f9b34fb')

        self.bms_read_characteristic = next(
            c for c in device_information_service.characteristics
            if c.uuid == '0000ff01-0000-1000-8000-00805f9b34fb')

        self.bms_write_characteristic = next(
            c for c in device_information_service.characteristics
            if c.uuid == '0000ff02-0000-1000-8000-00805f9b34fb')

        print("BMS found")
        self.bms_read_characteristic.enable_notifications()

    def characteristic_enable_notifications_succeeded(self, characteristic):
        super().characteristic_enable_notifications_succeeded(characteristic)

    def request_bms_data(self,request):
        print("BMS request data")
        self.response=bytearray()
        self.event.clear()
        self.bms_write_characteristic.write_value(request);

    def characteristic_enable_notifications_failed(self, characteristic, error):
        super.characteristic_enable_notifications_failed(characteristic, error)
        print("BMS notification failed:",error)

    def characteristic_value_updated(self, characteristic, value):
        print("BMS answering")
        self.response+=value
        if (self.response.endswith(b'w')):
            print("BMS answer:", self.response.hex())
            self.event.set()

    def characteristic_write_value_failed(self, characteristic, error):
        print("BMS write failed:",error)

    def wait(self):
        return self.event.wait(timeout=2)

def handle_client_connection(client_socket,manager):
    while 1:
        request = client_socket.recv(1024)
        if not request: break
        print('Received {}'.format(request.hex()))

        device.request_bms_data(request)
        if device.wait():
            client_socket.sendall(device.response)
        else:
            print('BMS timed out')

    print('Disconnect')
    client_socket.close()

def bluetooth_manager_thread(manager):
    manager.run()

if (len(sys.argv)<2):
    print("Usage: bmsinfo.py <device_uuid> <server_port>")
    sys.exit(0)

bluetooth_device = sys.argv[1]
bind_port = int(sys.argv[2])

manager = gatt.DeviceManager(adapter_name='hci0')
bluetooth_manager = threading.Thread(target=bluetooth_manager_thread, args=[manager,])
bluetooth_manager.start()
device = AnyDevice(mac_address=bluetooth_device, manager=manager)
device.connect()

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.bind((bind_ip, bind_port))
server.listen(5)  # max backlog of connections

print('BMS server for {} is listening on {}:{}'.format(bluetooth_device,bind_ip, bind_port))

while True:
    client_sock, address = server.accept()
    print('Accepted connection from {}:{}'.format(address[0], address[1]))
    client_handler = threading.Thread(
        target=handle_client_connection,
        args=(client_sock,manager,)
    )
    client_handler.start()

