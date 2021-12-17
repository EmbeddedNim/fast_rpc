import fast_rpc/routers/router_json_pubsub
import fast_rpc/socketserver
import fast_rpc/socketserver/mpack_jrpc_impl

import std/monotimes
import std/sysrand
import std/os

import mcu_utils/logging

import json
import fast_rpc/inet_types
import msgpack4nim/msgpack2json
import tables
import sugar

const
  VERSION = "1.0.0"

type
  SubId* = object
    uuid*: array[16, byte]
    okay*: bool

  SubscriptionArgs* = ref object
    subid*: SubId
    sender*: SocketClientSender 
    
  SubsTable = TableRef[SubId, Thread[SubscriptionArgs]]

proc newSubscription*(subs: var SubsTable,
                     sender: SocketClientSender,
                     subsfunc: proc (args: SubscriptionArgs) {.gcsafe, nimcall.}
                      ): SubId =
  var subid: SubId
  if urandom(subid.uuid):
    subid.okay = true

  subs[subid] = Thread[SubscriptionArgs]()
  var args = SubscriptionArgs(subid: subid, sender: sender)
  createThread(subs[subid], subsfunc, args)

  result = subid

proc run_micros(args: SubscriptionArgs) {.gcsafe.} = 
  var subId = args.subid
  var sender = args.sender
  echo("micros subs setup")

  while true:
    echo "sending mono time: ", "sub: ", $subId, " sender: ", repr(sender)
    let a = getMonoTime().ticks()
    var ts = int(a div 1000)
    var value = %* {"subscription": subId, "result": ts}
    var msg: string = value.fromJsonNode()

    let res = sender(msg)
    if not res: break
    os.sleep(1)

# Define RPC Server #
proc rpc_server*(): RpcRouter =
  var rt = createRpcRouter()
  var subs = SubsTable()

  rpc(rt, "version") do() -> string:
    result = VERSION

  rpc(rt, "micros_subscribe") do() -> JsonNode:
    var subid = subs.newSubscription(sender, run_micros)
    echo("micros subs setup")
    result = % subid

  rpc(rt, "add") do(a: int, b: int) -> int:
    result = a + b

  return rt

when isMainModule:
  let inetAddrs = [
    newInetAddr("0.0.0.0", 5555, Protocol.IPPROTO_UDP),
    newInetAddr("0.0.0.0", 5555, Protocol.IPPROTO_TCP),
  ]

  let router = rpc_server()
  startSocketServer(inetAddrs, newMpackJRpcServer(router, prefixMsgSize=true))
