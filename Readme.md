Deployment:
1) deploy on machine A
2) generate all certificates (not neceserly clients)
3) restart container (to update chown)
3a) syncthing should now copy configuration to remote machine
4) Confirm that configuration files on machine B have the same ownership
5) deploy to machine B