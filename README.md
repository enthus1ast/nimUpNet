# nimUpNet
general purpose tcp proxy / port forwarder

This is an async general purpose tcp proxy / port forwarder
This listens on a local port and transports 
data back and forth multiple gateways.
If one gateway is not online, we use the next.
Tested on linux and windows.

```
  upnet - upstream network
   tunnels all TCP connections
   established to the listen port
   to every gateway specified

  Usage:
   -g:host    gateway hostname, allowed multiple times!
   -l:port    listening port
   -x:key     XORs the payload with key
              (only entry and exit node needs key)

  Example:
   # listens on port 1337 and tunnel TCP
   # back and forth service.myhost.loc:8080
   upnet -l:1337 -g:service.myhost.loc:8080
   upnet -l:1337 -g:service.myhost.loc:8080 -g:192.168.2.155:8080
```
