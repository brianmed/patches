# Patches.pl

    Hopefully a straightforward patch management system.

    The web interface is used to display the system's patch level, and the
    ability to Update or Reboot a box.

### Installation

    1. Web interface

        - $ perl Patches.pl patches migrate                                                                          
        - $ perl Patches.pl patches remote domain.com 'http://domain.com:7000' 1-2-3-4-5-6 # domain.com url api_key
        - $ perl Patches.pl patches remote domain.org 'http://domain.org:7000' 7-8-9-0-1-2
        - $ perl Patches.pl daemon -l 'http://*:7000'

### Caveats

    1. CentOS centric; will glady update (with help) for other distributions,
       and hopefully BSD and Windows (maybe?).

    2. Must have 'sudo' rights.

### Example session

[![Patches](http://bmedley.org/patches_screen.gif)](http://bmedley.org/patches_screen.gif)
