/*
 * ANDES Lab - University of California, Merced
 * Flooding configuration component
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 */

configuration FloodingC {
   provides interface Flooding;
   uses interface SimpleSend as Sender;
   uses interface NeighborDiscovery;
}

implementation {
   components FloodingP;

   // Provide the Flooding interface
   Flooding = FloodingP.Flooding;

   // Wire the SimpleSend interface
   FloodingP.Sender = Sender;

   // Pass NeighborDiscovery through to FloodingP
   FloodingP.NeighborDiscovery = NeighborDiscovery;
}
