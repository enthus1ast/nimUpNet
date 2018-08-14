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
  Host* = tuple[host: string,port: Port]
  Hosts* = seq[Host]
  ProxyModes* = enum
    ModeSync, ModeAsync
  # UpstreamProxy = ref object of RootObj 
  UpstreamProxy* = ref object of RootObj
    master : bool
    gateways* : Hosts
    listenPort*: Port #= Port(7777)
    running*: bool # = true
    xorKey*: string # every bit gets XORed with every char in this string (and its position)
    lastWorking*: Host # we save the last working host to fasten internet browsers.
    mode*: ProxyModes

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

proc newUpstreamProxy*(gateways: Hosts, listenPort: Port, mode: ProxyModes = ModeAsync): UpstreamProxy =
  result = UpstreamProxy()
  result.listenPort = listenPort
  result.gateways = gateways
  result.mode = mode

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
      # buffer = await src.recv(SIZE, timeout=2,flags={SocketFlag.Peek, SocketFlag.SafeDisconn})
      buffer = await src.recv(SIZE, flags={SocketFlag.Peek, SocketFlag.SafeDisconn})
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

proc connectInOrder(upProxy: UpstreamProxy, gateways: Hosts, timeout = 3_000): Future[AsyncSocket] {.async.} = 
  ## tries to connect to all gateways one after another and in order.
  var upstreamSocket: AsyncSocket
  var connected: bool = false
  let gwList = (if upProxy.lastWorking.host.isNil(): upProxy.gateways else: @[upProxy.lastWorking] & upProxy.gateways)
  for actualGateway in gwList:
    if actualGateway == upProxy.lastWorking:
        continue
    if actualGateway.host.isNil or actualGateway.port.int == 0:
      echo "Gateway is invalid: ", actualGateway
      continue # we skip invalid gateway entries

    try:
      upstreamSocket = newAsyncSocket(buffered=true)
      var fut = upstreamSocket.connect(actualGateway.host, actualGateway.port)
      let inTime = await withTimeout(fut, timeout)
      if not inTIme :
        echo "Gateway timeouted:", actualGateway
        continue
      await fut 
      if fut.failed and fut.finished:
        continue
      connected = true
      echo "Set lastWorking to: ", actualGateway 
      upProxy.lastWorking = actualGateway # TODO
      result = upstreamSocket
      break
    except:
      echo "Could not connect to gateway ", actualGateway.host, ":", actualGateway.port 
      raise

proc connectToFastest(upProxy: UpstreamProxy, gateways: Hosts, timeout = 3_000): Future[AsyncSocket] {.async.} = 
  ## this tries to connect to all gateways simultaniously and 
  ## returns the AsyncSocket to the server which answers as fastest
  type SockHost = tuple[fut: Future[AsyncSocket], host: Host ]
  var futures = newSeq[SockHost]()
  for actualGateway in gateways:
    echo "requesting: ", actualGateway
    if actualGateway.host.isNil or actualGateway.port.int == 0:
      echo "Gateway is invalid (SKIPPING): ", actualGateway
      continue # we skip invalid gateway entries
    try:
      var fut = (asyncnet.dial(actualGateway.host, actualGateway.port, IPPROTO_TCP), actualGateway) 
      futures.add fut
    except:
      echo "dial fails"
      continue

  if futures.len == 0: 
    echo "no futures left"
    raise

  var timeoutFut = sleepAsync(timeout)
  while true:
    for sockHost in futures:
      echo sockHost.host, ": ", sockHost.fut.finished
      if sockHost.fut.finished == true and sockHost.fut.failed == false: 
        upProxy.lastWorking = sockHost.host
        return await sockHost.fut
      if timeoutFut.finished == true:
        echo "timeouted"
        raise 

    # Check if all are finished
    for sockHost in futures:
      if not sockHost.fut.finished: continue
      echo "all have finished"
      raise # all have finished
    await sleepAsync(150)

proc handleProxyClients(upProxy: UpstreamProxy, client: AsyncSocket) {.async.} = 
  var upstreamSocket: AsyncSocket
  var connected: bool = false
 
  # First connect to the last working proxy  
  if not upProxy.lastWorking.host.isNil:
    try:
      echo "Connect to lastWorking:", upProxy.lastWorking
      upstreamSocket = await upProxy.connectInOrder(@[upProxy.lastWorking], 1_000)
      connected = true
    except:
      connected = false

  # The try the others
  if connected == false:
    # If it fails to answer, we connect to the fastest
    try:
      var fut: Future[AsyncSocket]
      case upProxy.mode
      of ModeAsync:
        fut = upProxy.connectToFastest(@[upProxy.lastWorking] & upProxy.gateways, 1_000)
      of ModeSync:
        fut = upProxy.connectInOrder(@[upProxy.lastWorking] & upProxy.gateways, 1_000)
      upstreamSocket = await fut
      connected = true
    except:
      connected = false
      
  if connected == true:
    asyncCheck upProxy.pump(client, upstreamSocket)
    asyncCheck upProxy.pump(upstreamSocket,client )
  else:
    echo "No gateway let us connect...."
    client.close()
    return

proc serveUpstreamProxy*(upProxy: UpstreamProxy) {.async.} = 
  var server = newAsyncSocket()
  server.setSockOpt(OptReuseAddr, true)
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

proc toHostPort(s: string): Host = 
  var parts = s.split(":")
  if parts.len == 2:    
    result.host = parts[0]
    result.port = Port(parseInt(parts[1]))

when isMainModule:
  # proc foo(upProxy: UpstreamProxy): Future[void] {.async.} =
  #   for idx in 1..200:
  #     var host = toHostPort("jugene.code0.xyz:" & $(210+idx) )
  #     # echo host
  #     upProxy.gateways.add( host )
  #     # await sleepAsync 100

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
    echo "              (only entry and exit node needs key)"
    echo " --sync     Queries the gateways in order, one after another"
    echo " --async    [DEFAULT] Queries the gateways in parallel and use the fastest"
    #echo " --nolock   Does not try the last working gateway first, always query all"
    echo ""
    echo ""
    echo "Example:"
    echo " # listens on port 1337 and tunnel TCP"
    echo " # back and forth service.myhost.loc:8080"
    echo " upnet -l:1337 -g:service.myhost.loc:8080"
    echo ""
    echo " # Sync strictly try the gateways in order"
    echo " upnet -l:1337 --sync -g:service.myhost.loc:8080 -g:192.168.2.155:8080"

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
          of "sync":
            echo "set sync"
            upProxy.mode = ModeSync
          of "async":
            echo "set async"
            upProxy.mode = ModeAsync            
      else: 
        discard

  if upProxy.gateways.len == 0:
    writeHelp()
    quit()

  asyncCheck upProxy.serveUpstreamProxy()
  # asyncCheck upProxy.foo()
  runForever()
