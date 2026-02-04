# acep-ubuntu-rdp
This script will Setup RDP on Ubuntu Destkop system for a given user.


## Usage

```bash
git clone https://github.com/jehaverlack/acep-ubuntu-rdp.git
```

```bash
cd acep-ubuntu-rdp
```

```bash
./setup-rdp.sh
```

Enter the username to configure for RDP

Once completed logout of the console.

Goto a windows system.

SSH to the Ubuntu system with the following command:
```bash
ssh -L 3390:localhost:3389 user@server
```

Open the remote desktop client and connect to the server on port 3390

- `localhost:3390`

Connect and login.

