import net
import asyncnet, asyncdispatch
import parseopt2
import parseutils
import strutils

const SIZE = 1024 

type 

  Host = tuple[host: string,port: Port]
  Hosts = seq[Host]

  UpstreamProxy = object of RootObj 
    master : bool
    gateways* : Hosts
    listenPort*: Port #= Port(7777)
    running*: bool # = true
    xorKey*: string # every bit gets XORed with every char in this string (and its position)

proc xorPayload(upProxy: UpstreamProxy, buffer: string): string = 
  ## xors the buffer with the xorKey given in the upstreamProxy object
  if upProxy.xorKey == "":
    return buffer
  result = ""
  var cbuf: char
  for bufferChar in buffer:
    cbuf = bufferChar
    for i, keyChar in upProxy.xorKey:
      # we use the position of the char in the key
      # to harden this a bit....
      cbuf = chr( ((keyChar.int + i) mod 255) xor cbuf.int)
    result.add(cbuf)


proc newUpstreamProxy(gateways: Hosts, listenPort: Port): UpstreamProxy =
  result = UpstreamProxy()
  result.listenPort = listenPort
  result.gateways = gateways

proc isMaster(upProxy: UpstreamProxy): bool = 
  return upProxy.master


proc pump(upProxy: UpstreamProxy, src, dst: AsyncSocket) {.async.} = 
  ## transfers data back and forth.
  ## since asyncnet recv cannot timeout, we have to 
  ## peek the data first and check how much data we have.
  ## Then it reads that amounth of data from buf
  ## TODO when we found a better solution change this...
  while true:
    var buffer: string
    try:
      buffer = await src.recv(SIZE, flags={SocketFlag.Peek, SocketFlag.SafeDisconn})
    except:
      buffer = ""

    if buffer.len > 0:
      try:
        discard await src.recv(buffer.len)
      except:
        buffer = ""
    else:
      try:
        buffer = await src.recv(1)
      except:
        buffer = ""        

    if buffer == "":
      echo "client _OR_ gateways diconnects TODO"
      src.close()
      dst.close()    
      break
    else:
      await dst.send(upProxy.xorPayload(buffer))


proc handleProxyClients(upProxy: UpstreamProxy, client: AsyncSocket) {.async.} = 
  var upstreamSocket: AsyncSocket
  var connected: bool = false
  for actualGateway in upProxy.gateways:
    # echo actualGateway
    try:
      upstreamSocket = newAsyncSocket(buffered=true)
      await upstreamSocket.connect(actualGateway.host, actualGateway.port)
      connected = true
      echo "[X] -> ", actualGateway.host, ":", actualGateway.port 
      break
    except:
      # echo getCurrentExceptionMsg()
      echo "[ ] -> ", actualGateway.host, ":", actualGateway.port 

  if connected == true:
    asyncCheck upProxy.pump(client, upstreamSocket)
    asyncCheck upProxy.pump(upstreamSocket,client )
  else:
    echo "No gateway let us connect...."
    client.close()
    return


proc serveUpstreamProxy(upProxy: UpstreamProxy) {.async.} = 
  var server = newAsyncSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(upProxy.listenPort)
  server.listen()
  echo "Bound to upProxy.listenPort: ", upProxy.listenPort

  while true:
    let client = await server.accept()
    echo "Client connected"
    asyncCheck upProxy.handleProxyClients(client)


proc writeHelp() = 
  echo "upnet - upstream network"
  echo " tunnels all TCP connections"
  echo " established to the listen port"
  echo " to the gateway:gatewayPort"
  echo ""
  echo "Usage:"
  echo " -g:host:port   gateway hostname, allowed multiple times!"
  echo " -l:port        listening port"
  echo " -x:key         XORs the payload with key"
  echo "                (only entry and exit node needs key)"
  echo ""
  echo "Example:"
  echo " # listens on port 1337 and tunnel TCP"
  echo " # back and forth service.myhost.loc:8080"
  echo " upnet -l:1337 -g:service.myhost.loc:8080"
  echo ""
  echo " # first service.myhost.loc then 192.168.2.155"
  echo " upnet -l:1337 -g:service.myhost.loc:8080 -g:192.168.2.155:8080"


proc toHostPort(s: string): Host = 
  var parts = s.split(":")
  if parts.len == 2:    
    result.host = parts[0]
    result.port = Port(parseInt(parts[1]))


# create proxy object with default configuration
# var upProxy = newUpstreamProxy( @[("127.0.0.1",Port(8888))] ,Port(8877)) 
var upProxy = newUpstreamProxy( @[] ,Port(8877)) 

# Parse command line options.
for kind, key, val in getopt():
  case kind
    of cmdLongOption, cmdShortOption:
      case key
        of "help", "h": 
          writeHelp()
          quit()
        of "g":
          upProxy.gateways.add(val.toHostPort())
        of "l":
          var portnum = 0
          discard parseInt(val, portnum)
          upProxy.listenPort = Port( portnum )   
        of "x":
          upProxy.xorKey = val
    else: 
      discard

if upProxy.gateways.len == 0:
  echo "no gateways specified. Add a few with: '-g:host:port'"
  writeHelp()
  quit()

echo upProxy
asyncCheck upProxy.serveUpstreamProxy()
runForever()
