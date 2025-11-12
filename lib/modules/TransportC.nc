configuration TransportC {
    provides interface Transport;
    uses interface SimpleSend as Sender;
}

implementation{
    components TransportP;
    components new TimerMilliC() as RetransmitTimer;
    components new TimerMilliC() as TransportTimer;
    components RandomC;

    Transport = TransportP.Transport;
    TransportP.Sender = Sender;
    TransportP.RetransmitTimer -> RetransmitTimer;
    TransportP.TransportTimer -> TransportTimer;
    TransportP.Random -> RandomC;

}