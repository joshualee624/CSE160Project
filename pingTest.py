from TestSim import TestSim
# stop transferring after message is recieved at destination. 
def main():
    # Get simulation ready to run.
    s = TestSim();

    # Before we do anything, lets simulate the network off.
    s.runTime(1);

    # Load the the layout of the network.
    s.loadTopo("long_line.topo");

    # Add a noise model to all of the motes.
    s.loadNoise("no_noise.txt");

    # Turn on all of the sensors.
    s.bootAll();

    # Add the main channels. These channels are declared in includes/channels.h
    s.addChannel(s.COMMAND_CHANNEL);
    s.addChannel(s.GENERAL_CHANNEL);
    s.addChannel(s.NEIGHBOR_CHANNEL);
    # s.addChannel(s.FLOODING_CHANNEL);

    # After sending a ping, simulate a little to prevent collision.
    s.runTime(30);
    s.ping(2, 3, "Hello, World");
    s.runTime(1);
    s.ping(1, 10, "Hi!");
    s.runTime(5);
    s.ping(3, 19, "test 1");
    s.runTime(5);
    s.moteOff(5);
    s.runTime(5);
    s.ping(4, 7, "test 2");
    s.runTime(5);
    for i in range(1, 20):
        s.neighborDMP(i)       #prints the neighboring nodes of node i:
        s.runTime(1)
    

if __name__ == '__main__':
    main()