@{
    Inherits    = 'base'
    Name        = 'zenbook-s16-um5606g'
    Description = 'ASUS Zenbook S 16 UM5606G (Ryzen AI 9 465, 32 GB, 1 TB, 16" 2880x1800 OLED touch, 83 Wh, Windows 11 Pro).'

    # Mismatch: FAIL for Model, CPU, RAM, disk size, edition; WARN for everything else.
    Expected = @{
        Manufacturer      = 'ASUS*'
        Model             = '*UM5606*'
        Cpu               = '*Ryzen AI 9 465*'
        RamGB             = 32
        DiskGB            = 1000
        Edition           = '*Pro*'
        BatteryDesignWh   = 83
        DisplayResolution = '2880x1800'
        Touch             = $true
    }

    # OLED care: short screen-off and sleep timeouts (minutes).
    Power = @{
        MonitorAcMin = 10
        MonitorDcMin = 5
        SleepAcMin   = 30
        SleepDcMin   = 15
    }

    # Opt-in at run time with -Enable <key>.
    Optional = @{
        DarkMode        = 'Windows + apps dark theme'
        AutoHideTaskbar = 'Taskbar hides until the pointer reaches the bottom edge'
    }
}
