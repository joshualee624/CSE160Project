#include<Timer.h>
#include "../../includes/packet.h"
#include "../../includes/channels.h"

module NeighborDiscoveryP{
    provides interface NeighborDiscovery;

    uses interface Timer<TMilli> as neighborTimer;
    uses interface Random;
    uses interface SimpleSend;
}

implementation {
     pack msg;
     uint16_t seqCount = 0;
     uint16_t neighbors[19];
     uint8_t numNeighbors = 0;
     bool hasNeighbor(uint16_t id){
        int i;
         for(i = 0; i < numNeighbors; i++){
             if(neighbors[i] == id) return TRUE;
         }
         return FALSE;
     }
    

    task void search();  //forward declaration
    bool timerRunning = FALSE;
    command error_t NeighborDiscovery.findNeighbors() {  
        dbg(NEIGHBOR_CHANNEL, "Finding Neighbors");
        if (timerRunning) return EBUSY;
        call neighborTimer.startPeriodic(5000 + (call Random.rand16() % 5000));
        timerRunning = TRUE;
        post search();
        return SUCCESS;
    }
    command void NeighborDiscovery.handle(pack *p){
        if(p->protocol == PROTOCOL_ND){
            if(!hasNeighbor(p->src) && numNeighbors < 19){
                neighbors[numNeighbors] = p->src;
                numNeighbors++;
                dbg(NEIGHBOR_CHANNEL, "Neighbor Found: %d\n", p->src);
            }
        }
    }
        



    

    task void search(){
        // "logic sned the msg, if someone responds, save its id inside table"
 
            msg.dest = AM_BROADCAST_ADDR;
            msg.src = TOS_NODE_ID;
            msg.seq = seqCount++; 
            msg.TTL = 1; 
            msg.protocol = PROTOCOL_ND;
            call SimpleSend.send(msg, msg.dest);

    }

    event void neighborTimer.fired(){
      post search();
    }


    command void NeighborDiscovery.printNeighbors(){
        int i;
        for(i = 0; i < numNeighbors; i++){
            dbg(NEIGHBOR_CHANNEL, "Neighbor ID: %d\n", neighbors[i]);
        }
    }


}