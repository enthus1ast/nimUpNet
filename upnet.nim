import net
import asyncnet, asyncdispatch
# import sequtils
import parseopt2
import parseutils

const SIZE = 1024
# const SIZE = 1
# const SIZE = 10

type 
  UpstreamProxy = object of RootObj 
    master : bool
    gateway* : string
    gatewayPort*: Port
    listenPort*: Port #= Port(7777)
    running*: bool # = true
    xorKey*: string # every bit gets XORed with every char in this string


proc xorPayload(upProxy: UpstreamProxy, buffer: string): string = 
  ## xors the buffer with the xorKey given in the upstreamProxy object
  if upProxy.xorKey == "":
    return buffer
  result = ""
  var cbuf: char
  for bufferChar in buffer:
    cbuf = bufferChar
    for i, keyChar in upProxy.xorKey:
      cbuf = chr( (keyChar.int + i) xor cbuf.int)
    result.add(cbuf)


proc newUpstreamProxy(gatewayStr: string, gatewayPort: Port, listenPort: Port): UpstreamProxy =
  result = UpstreamProxy()
  result.listenPort = listenPort

  if gatewayStr != "":
    result.gateway = gatewayStr
    result.gatewayPort = gatewayPort
    result.master = false # couse we've got a gateway, we are not the master
  else:
    result.master = true # we've got not gateway, we are the endpoint, the master


proc isMaster(upProxy: UpstreamProxy): bool = 
  return upProxy.master


proc pump(upProxy: UpstreamProxy, src, dst: AsyncSocket) {.async.} = 
  while true:
    var buffer: string
    try:
      buffer = await src.recv(SIZE, timeout=2,flags={SocketFlag.Peek, SocketFlag.SafeDisconn})
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
      src.close()
      dst.close()
      # echo "src.isClosed() ", src.isClosed()
      # echo "dst.isClosed() ", dst.isClosed()      
      break
    else:
      await dst.send( upProxy.xorPayload(buffer) )


proc handleProxyClients(upProxy: UpstreamProxy, client: AsyncSocket) {.async.} = 
  var upstreamSocket = newAsyncSocket(buffered=true)
  try:
    await upstreamSocket.connect(upProxy.gateway, upProxy.gatewayPort)
  except:
    echo "Could not connect to gateway ", upProxy.gateway, ":", upProxy.gatewayPort 
    client.close()
    return


  asyncCheck upProxy.pump(client, upstreamSocket)
  asyncCheck upProxy.pump(upstreamSocket,client )


proc serveUpstreamProxy(upProxy: UpstreamProxy) {.async.} = 
  var server = newAsyncSocket()
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
  echo " -g:host    gateway hostname"
  echo " -gp:port   gateway port"
  echo " -l:port    listening port"
  echo " -x:key     XORs the payload with key"
  echo "            (only entry and exit node needs key)"
  echo ""
  echo "Example:"
  echo " # listens on port 1337 and tunnel TCP"
  echo " # back and forth service.myhost.loc:8080"
  echo " upnet -l:1337 -g:service.myhost.loc -gp:8080"


var upProxy = newUpstreamProxy("127.0.0.1",Port(8888),Port(8877)) 

# Parse command line options.
for kind, key, val in getopt():
  case kind
    of cmdLongOption, cmdShortOption:
      case key
        of "help", "h": 
          writeHelp()
          quit()
        of "g":
          upProxy.gateway = val
        of "gp":
          var portnum = 0
          discard parseInt(val, portnum)
          upProxy.gatewayPort = Port( portnum )
        of "l":
          var portnum = 0
          discard parseInt(val, portnum)
          upProxy.listenPort = Port( portnum )   
        of "x":
          upProxy.xorKey = val
    else:
      discard

# upProxy.xorKey = "hallo"
# echo upProxy.xorPayload("i am the payload")

echo upProxy # echo configuration
asyncCheck upProxy.serveUpstreamProxy()
runForever()