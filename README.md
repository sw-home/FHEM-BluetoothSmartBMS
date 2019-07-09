# FHEM-BluetoothSmartBMS
Get readings from the Bluetooth Smart BMS from https://www.lithiumbatterypcb.com/ in FHEM

Use _bluetoothctl_ to search and connect to the Bluetooth BMS

    sudo bluetoothctl
    
    scan on
    
    [NEW] Device A4:C1:38:0A:E3:B3 xiaoxiang BMS
    
    connect A4:C1:38:0A:E3:B3

After that, exit the _bluetoothctl_ and start the TCP server like this:

    sudo python3 bmstcp.py A4:C1:38:0A:E3:B3 9998

And finally define the device in FHEM

    defmod BatteryPack1 GenericSmartBMS raspberry.ip 9998 60 1



