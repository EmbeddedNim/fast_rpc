import nativesockets, net, selectors, posix, tables

export nativesockets, net, selectors, posix, tables

type
  InetAddress* = object
    # Combined type for a remote IP address and service port
    host*: IpAddress
    port*: Port
    protocol*: net.Protocol
    socktype*: net.SockType

  SocketServerInfo*[T] = ref object 
    select*: Selector[T]
    servers*: seq[Socket]
    clients*: ref Table[SocketHandle, Socket]
    serverImpl*: SocketServerImpl[T]

  SocketServerHandler*[T] = proc (srv: SocketServerInfo[T],
                                  selected: ReadyKey,
                                  client: Socket,
                                  data: T) {.nimcall.}

  SocketServerImpl*[T] = ref object
    data*: T
    readHandler*: SocketServerHandler[T]
    writeHandler*: SocketServerHandler[T]

type 
  InetClientDisconnected* = object of OSError
  InetClientError* = object of OSError

proc newInetAddr*(host: string, port: int, protocol = net.IPPROTO_TCP): InetAddress =
  result.host = parseIpAddress(host)
  result.port = Port(port)
  result.protocol = protocol
  case protocol:
  of net.IPPROTO_TCP:
    result.socktype = SockType.SOCK_STREAM
  of net.IPPROTO_UDP:
    result.socktype = SockType.SOCK_DGRAM
  else:
    raise newException(ValueError, "unhandled protocol - specify seperately")

proc createServerInfo*[T](selector: Selector[T],
                          servers: seq[Socket],
                          serverImpl: SocketServerImpl
                          ): SocketServerInfo[T] = 
  result = new(SocketServerInfo[T])
  result.servers = servers
  result.select = selector
  result.serverImpl = serverImpl
  result.clients = newTable[SocketHandle, Socket]()

proc inetDomain*(inetaddr: InetAddress): nativesockets.Domain = 
  case inetaddr.host.family:
  of IpAddressFamily.IPv4:
    result = Domain.AF_INET
  of IpAddressFamily.IPv6:
    result = Domain.AF_INET6 