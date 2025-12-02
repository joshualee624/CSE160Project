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

t = Tossim([])
r = t.radio()

# Enable dbg channels we care about
for ch in ["transport"]:
    t.addChannel(ch, sys.stdout)

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

if __name__ == "__main__":
    NUM_NODES = 10
    TOPO = "topo/topo.txt"
    NOISE = "noise/meyer-heavy.txt"
    START_TIME = 100001

    loadTopo(TOPO)
    loadNoise(NOISE, NUM_NODES)
    bootAll(NUM_NODES, startTime=START_TIME)

    # Run until after all motes have booted before issuing commands
    while t.time() < START_TIME + 2000:
        t.runNextEvent()

    # Test: node 1 = server, node 2 = client
    cmdTestServer(1, 10)
    cmdTestClient(2, 1, 20, 10, 100)

    # Run the simulation
    for _ in range(200000):
        t.runNextEvent()
