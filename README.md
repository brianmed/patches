# Patches.pl

    Hopefully a very simple patch management system.

    There are several parts:

        - Web interface
        - Minion workers
        - Enqueing jobs

    The web interface is used to display the system's patch level, and the ability to Update or Reboot a box.

    The minion workers are there to query the patch level, update the patches, or reboot the box.

    Enqueing jobs is usually done from either the command-line, cron, or the web interface.

### Installation

    1. Web interface

        - $ perl Patches.pl daemon

        - Usually you just need one of these; I don't think more would be a problem.

    2. Minion workers 

        - $ perl Patches.pl minion worker

        - One per watched host is needed.

    3. Enqueing jobs

        - $ perl Patches.pl enqueue query
