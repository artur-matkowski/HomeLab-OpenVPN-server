Deployment:
1) deploy on machine A
2) generate all certificates (not neceserly clients)
3) restart container (to update chown)
3a) syncthing should now copy configuration to remote machine
4) Confirm that configuration files on machine B have the same ownership
5) deploy to machine B

Note:
1) some files have to be ignored during synchronization:
- server.conf
- openvpn-status.log

2) How to Fix It in KDE (Plasma) NetworkManager
- Open System Settings → Network (or Connections).
- Find your VPN connection and Edit it.
- Go to the IPv4 or IPv6 tab (depending on which you use).
- Click the “Routes…” button to see advanced route options.
- Check or uncheck any boxes that say:
   * “Use only for resources on its network” (This might have different wording depending on KDE version.)


   TODO:
   - after cleaning env, generate client no longer has adresses of all servers. all instances have to create a file with server adress, in clientDir, and when cient cert is created, that dir has to be scanned for all 'registered' servers