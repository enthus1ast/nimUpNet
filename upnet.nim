#
#
#                    upnet 
#             (c) Copyright 2017
#                 David Krause
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#
## This is an async general purpose tcp proxy / port forwarder
## This listens on a local port and transports 
## data back and forth multiple gateways.
## If one gateway is not online, we use the next.
## Tested on linux and windows.

## BUGs:
##  - ipv6 not working!
##  - store last working proxy
##


import net
import asyncnet, asyncdispatch
import parseopt2
import parseutils
import strutils

const SIZE = 1024 ## max size the buffer could be
                  ## but since we peek on the sockets,
                  ## this buffer gets not filled completely
                  ## anyway...

type 
  Host = tuple[host: string,port: Port]
  Hosts = seq[Host]

  # UpstreamProxy = ref object of RootObj 
  UpstreamProxy = object of RootObj
    master : bool
    gateways* : Hosts
    listenPort*: Port #= Port(7777)
    running*: bool # = true
    xorKey*: string # every bit gets XORed with every char in this string (and its position)
    lastWorking*: Host # we save the last working host to fasten internet browsers.


var lastWorking: Host ## TODO this should be the last working of the upnet object!!!


proc xorPayload(upProxy: UpstreamProxy, buffer: string): string = 
  ## xors the buffer with the xorKey given in the upstreamProxy object
  ## only the entry and the exit needs to have the same key. 
  ## since this is essentially XOR this utilize the same key for "encryption" or "decryption"
  ## This is NOT a real crypto!
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
      ## Peek, so input buffer remains the same!
      buffer = await src.recv(SIZE, timeout=2,flags={SocketFlag.Peek, SocketFlag.SafeDisconn})
    except:
      buffer = ""

    if buffer.len > 0:
      try:
        discard await src.recv(buffer.len) # TODO (better way?) we empty the buffer by reading it 
      except:
        buffer = ""
    else:
      try:
        buffer = await src.recv(1) # we wait for new data...
      except:
        buffer = ""        

    if buffer == "":
      # if one side closes we close both sides!
      src.close()
      dst.close()    
      break
    else:
      await dst.send(upProxy.xorPayload(buffer))


proc handleProxyClients(upProxy: UpstreamProxy, client: AsyncSocket) {.async.} = 
  var upstreamSocket: AsyncSocket
  var connected: bool = false
  # for actualGateway in @[upProxy.lastWorking] & upProxy.gateways:
  # for actualGateway in upProxy.gateways:  
  for actualGateway in @[lastWorking] & upProxy.gateways: # TODO
    echo "trying ", actualGateway
    if actualGateway.host.isNil or actualGateway.port.int == 0:
      echo "Gateway is invalid: ", actualGateway
      continue # we skip invalid gateway entries

    try:
      upstreamSocket = newAsyncSocket(buffered=true)
      await upstreamSocket.connect(actualGateway.host, actualGateway.port)
      connected = true
      echo "Set lastWorking to: ", actualGateway 
      lastWorking = actualGateway # TODO
      break
    except:
      # echo getCurrentExceptionMsg()
      echo "Could not connect to gateway ", actualGateway.host, ":", actualGateway.port 
    # upProxy.lastWorking = actualGateway


  if connected == true:
    asyncCheck upProxy.pump(client, upstreamSocket)
    asyncCheck upProxy.pump(upstreamSocket,client )
  else:
    echo "No gateway let us connect...."
    client.close()
    return

proc serveUpstreamProxy(upProxy: UpstreamProxy) {.async.} = 
  var server = newAsyncSocket()
  server.bindAddr(upProxy.listenPort)
  server.listen()
  echo "Bound to upProxy.listenPort: ", upProxy.listenPort
  echo "Will forward to:"
  for gw in upProxy.gateways:
    echo "\t", gw

  while true:
    let client = await server.accept()
    echo "Client connected"
    asyncCheck upProxy.handleProxyClients(client)


proc writeHelp() = 
  echo "upnet - upstream network"
  echo " tunnels all TCP connections"
  echo " established to the listen port"
  echo " to every gateway specified"
  echo ""
  echo "Usage:"
  echo " -g:host    gateway hostname, allowed multiple times!"
  echo " -l:port    listening port"
  echo " -x:key     XORs the payload with key"
  echo "            (only entry and exit node needs key)"
  echo ""
  echo "Example:"
  echo " # listens on port 1337 and tunnel TCP"
  echo " # back and forth service.myhost.loc:8080"
  echo " upnet -l:1337 -g:service.myhost.loc:8080"
  echo " upnet -l:1337 -g:service.myhost.loc:8080 -g:192.168.2.155:8080"


proc toHostPort(s: string): Host = 
  var parts = s.split(":")
  if parts.len == 2:    
    result.host = parts[0]
    result.port = Port(parseInt(parts[1]))

# create proxy object with default configuration
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
  writeHelp()
  quit()

# echo upProxy
# echo @[upProxy.lastWorking] & upProxy.gateways
asyncCheck upProxy.serveUpstreamProxy()
runForever()