# -*- coding: utf-8 -*-

from TOSSIM import *
from CommandMsg import CommandMsg
import sys

# Command IDs (from command.h)
CMD_PING = 0
CMD_NEIGHBOR_DUMP  = 1
CMD_LINKSTATE_DUMP = 2
CMD_ROUTETABLE_DUMP = 3
CMD_TEST_CLIENT = 4
CMD_TEST_SERVER = 5
CMD_KILL = 6
CMD_ERROR = 9
CMD_CLIENT_CLOSE = 7
CMD_HELLO = 10
CMD_MSG = 11
CMD_WHISPER = 12
CMD_LISTUSR = 13
CMD_SET_APP_SERVER = 14     
CMD_SET_APP_CLIENT = 15

t = Tossim([])
t.randomSeed(12345)
r = t.radio()

# Enable dbg channels we care about
for ch in ["transport"]:
    t.addChannel(ch, sys.stdout)


def pack_string(s, max_len=25):
    """Return a list of byte values for ASCII string s, truncated to max_len."""
    b = [ord(c) & 0xFF for c in s]
    return b[:max_len]

def cmdHello(nodeId, serverNode, username, clientPort):
    params = []
    params.append(int(serverNode) & 0xFF)
    params.append(int(clientPort) & 0xFF)
    params.extend(pack_string(username, max_len=23))  # 2 + 23 = 25 max
    sendCommand(nodeId, CMD_HELLO, params)

def cmdMsg(nodeId, message):
    params = pack_string(message, max_len=25)
    sendCommand(nodeId, CMD_MSG, params)

def cmdWhisper(nodeId, username, message):
    params = []
    u_bytes = pack_string(username, max_len=10)  # up to you, just keep total ≤ 25
    m_bytes = pack_string(message, max_len=14)   # 10 + 1 + 14 = 25
    params.extend(u_bytes)
    params.append(0)  # separator
    params.extend(m_bytes)
    sendCommand(nodeId, CMD_WHISPER, params)

def cmdListUsr(nodeId):
    sendCommand(nodeId, CMD_LISTUSR, [])

def sendCommand(destNode, cmdId, params):
    msg = CommandMsg()
    msg.set_dest(destNode)
    msg.set_id(cmdId)

    # clear payload
    for i in range(25):
        msg.setElement_payload(i, 0)

    # set params one byte at a time
    for i, p in enumerate(params):
        if i >= 25:
            break
        msg.setElement_payload(i, int(p) & 0xFF)

    pkt = t.newPacket()
    pkt.setType(CommandMsg.get_amType())
    pkt.setData(msg.data)
    pkt.setDestination(destNode)

    pkt.deliver(destNode, t.time() + 1)
    t.runNextEvent()

def cmdTestServer(address, port):
    sendCommand(address, CMD_TEST_SERVER, [port])

def cmdTestClient(address, dest, srcPort, destPort, transfer):
    params = [
        int(dest) & 0xFF,
        int(srcPort) & 0xFF,
        int(destPort) & 0xFF,
        int(transfer) & 0xFF
    ]
    sendCommand(address, CMD_TEST_CLIENT, params)

def loadTopo(filename):
    f = open(filename, "r")
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        a, b, gain = line.split()
        r.add(int(a), int(b), float(gain))
    f.close()

def loadNoise(filename, numNodes):
    f = open(filename, "r")
    for line in f:
        line = line.strip()
        if not line:
            continue
        val = int(line)
        for i in range(1, numNodes + 1):
            t.getNode(i).addNoiseTraceReading(val)
    f.close()
    for i in range(1, numNodes + 1):
        t.getNode(i).createNoiseModel()

def bootAll(numNodes, startTime=100001):
    for i in range(1, numNodes + 1):
        n = t.getNode(i)
        n.bootAtTime(startTime + i)

# if __name__ == "__main__":
#     NUM_NODES = 10
#     TOPO = "topo/topo.txt"
#     NOISE = "noise/meyer-heavy.txt"
#     START_TIME = 100001

#     loadTopo(TOPO)
#     loadNoise(NOISE, NUM_NODES)
#     bootAll(NUM_NODES, startTime=START_TIME)

#     # Run until after all motes have booted before issuing commands
#     while t.time() < START_TIME + 2000:
#         t.runNextEvent()

#     # Test: node 1 = server, node 2 = client
#     cmdTestServer(1, 10)
#     cmdTestClient(2, 1, 20, 10, 100)

#     # Run the simulation
#     for _ in range(200000):
#         t.runNextEvent()
if __name__ == "__main__":
    NUM_NODES = 10
    TOPO = "topo/topo.txt"
    NOISE = "noise/meyer-heavy.txt"
    START_TIME = 100001

    loadTopo(TOPO)
    loadNoise(NOISE, NUM_NODES)
    bootAll(NUM_NODES, startTime=START_TIME)

    while t.time() < START_TIME + 2000:
        t.runNextEvent()

    # Start chat server on node 1 (we'll handle this in CommandHandler/ChatServer)
    cmdTestServer(1, 41)   # or later change to a dedicated CMD if you want

    # Tell node 2 to connect to node 1 and say hello
    cmdHello(2, 1, "josh", 20)

    for _ in range(50000):
        t.runNextEvent()

    # Later, send a broadcast message from node 2
    cmdMsg(2, "Hello everyone!")

    cmdWhisper(2, "josh", "hi there")

    # Ask node 2 to request list of users
    cmdListUsr(2)

    for _ in range(200000):
        t.runNextEvent()
