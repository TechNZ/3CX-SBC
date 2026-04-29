Requirements:

  ARM64 Based SBC (Raspberry PI 4+, RadXa Rock 4C+) running Debian Bookworm.
  This can be run onto of an existing install however a fresh install (preferably minimial) is recommended



To Install:

  As a user with sudo permissions run the below command.

  New Version (Untested)
  
 `curl -fsSL https://raw.githubusercontent.com/TechNZ/3CX-SBC/refs/heads/main/setup.sh | sudo bash`

Old Version

`curl -fsSL https://raw.githubusercontent.com/TechNZ/3CX-SBC/refs/heads/main/old_setup.sh | sudo bash`


To configure:

 open the web  interface located at the systems IP, eg: http://192.168.0.11/
 upload a wireguard config exported from  your  wireguard server
 enter the provisioning URL and provisioning key from your 3CX admin interface
