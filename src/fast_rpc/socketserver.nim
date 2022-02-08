import nativesockets
import net
import selectors
import tables
import posix

# export net, selectors, tables, posix

import mcu_utils/logging
import inet_types
import socketservers/sockethelpers

export sockethelpers
export inet_types

import sequtils

proc processWrites[T](srv: ServerInfo[T], selected: ReadyKey) = 
  logDebug("[SocketServer]::", "processWrites:", "selected:fd:", selected.fd)
  let sourceClient = srv.receivers[SocketHandle(selected.fd)]
  if srv.impl.writeHandler != nil:
    srv.impl.writeHandler(srv, selected, sourceClient)

proc processEvents[T](srv: ServerInfo[T], selected: ReadyKey) = 
  logDebug("[SocketServer]::", "processUserEvents:", "selected:fd:", selected.fd)
  # let sourceClient = srv.userEvents[SocketHandle(selected.fd)]
  for evt, chan in srv.userEvents.pairs():
    let val = selected in evt
    logDebug("[SocketServer]::", "processUserEvents:", "userEvet:", val)
  # if srv.impl.eventHandler != nil:
    # srv.impl.eventHandler(srv, selected, sourceClient)

proc processReads[T](srv: ServerInfo[T], selected: ReadyKey) = 
  let handle = SocketHandle(selected.fd)
  logDebug("[SocketServer]::", "processReads:", "selected:fd:", selected.fd)
  logDebug("[SocketServer]::", "processReads:", "listners:fd:", srv.listners.keys().toSeq().mapIt(it.int()).repr())
  logDebug("[SocketServer]::", "processReads:", "receivers:fd:", srv.receivers.keys().toSeq().mapIt(it.int()).repr())

  if srv.listners.hasKey(handle):
    let server = srv.listners[handle]
    logDebug("process reads on:", "fd:", selected.fd, "srvfd:", server.getFd().int)
    if SocketHandle(selected.fd) == server.getFd():
      var client: Socket = new(Socket)
      server.accept(client)

      client.getFd().setBlocking(false)
      srv.receivers[client.getFd()] = client

      let id: int = client.getFd().int
      logDebug("client connected:", "fd:", id)

      registerHandle(srv.selector, client.getFd(), {Event.Read}, SOCK_STREAM)
      return

  if srv.receivers.hasKey(SocketHandle(selected.fd)):
    let sourceClient = srv.receivers[SocketHandle(selected.fd)]
    let sourceFd = selected.fd
    logDebug("srv client:", "fd:", selected.fd)

    try:
      if srv.impl.readHandler != nil:
        srv.impl.readHandler(srv, selected, sourceClient)

    except InetClientDisconnected:
      var client: Socket
      discard srv.receivers.pop(sourceFd.SocketHandle, client)
      srv.selector.unregister(sourceFd)
      discard posix.close(sourceFd.cint)
      logError("client disconnected: fd: ", $sourceFd)

    except InetClientError:
      srv.receivers.del(sourceFd.SocketHandle)
      srv.selector.unregister(sourceFd)

      discard posix.close(sourceFd.cint)
      logError("client read error: ", $(sourceFd))

    return

  raise newException(OSError, "unknown socket id: " & $selected.fd.int)

proc startSocketServer*[T](ipaddrs: openArray[InetAddress],
                           serverImpl: Server[T]) =
  # Initialize and setup a new socket server
  var select: Selector[SockType] = newSelector[SockType]()
  var listners = newSeq[Socket]()
  var receivers = newSeq[Socket]()

  logInfo "[SocketServer]::", "starting"
  for ia in ipaddrs:
    logInfo "[SocketServer]::", "creating socket on:", "ip:", $ia.host, "port:", $ia.port, $ia.inetDomain(), "sockType:", $ia.socktype, $ia.protocol

    var socket = newSocket(
      domain=ia.inetDomain(),
      sockType=ia.socktype,
      protocol=ia.protocol,
      buffered = false
    )
    logDebug "[SocketServer]::", "socket started:", "fd:", socket.getFd().int

    socket.setSockOpt(OptReuseAddr, true)
    socket .getFd().setBlocking(false)
    socket.bindAddr(ia.port)

    var evts: set[Event]
    var stype: SockType

    if ia.protocol in {Protocol.IPPROTO_TCP}:
      socket.listen()
      listners.add(socket)
      stype = SOCK_STREAM
      evts = {Event.Read}
    elif ia.protocol in {Protocol.IPPROTO_UDP}:
      receivers.add(socket)
      stype = SOCK_DGRAM
      evts = {Event.Read}
    else:
      raise newException(ValueError, "unhandled protocol: " & $ia.protocol)

    registerHandle(select, socket.getFd(), evts, stype)
  
  for queue in serverImpl.queues:
    logDebug "[SocketServer]::", "userEvent:register:", repr(queue.evt)
    registerEvent(select, queue.evt, SOCK_RAW)

  var srv = newServerInfo[T](serverImpl, select, listners, receivers, serverImpl.queues)

  while true:
    var keys: seq[ReadyKey] = select.select(-1)
    logDebug "[SocketServer]::keys:", repr(keys)
  
    for key in keys:
      logDebug "[SocketServer]::key:", repr(key)
      if Event.Read in key.events:
          srv.processReads(key)
      if Event.User in key.events:
          srv.processEvents(key)
      if Event.Write in key.events:
          srv.processWrites(key)
    
    if serverImpl.postProcessHandler != nil:
      serverImpl.postProcessHandler(srv, keys)

  
  select.close()
  for listner in srv.listners.values():
    listner.close()