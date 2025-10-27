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
     uint32_t lastHeard[19]; // keep track of the time we last heard from each neighbor to determine if they should be dropped
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
            if(numNeighbors < 19){                      //!hasNeighbor(p->src) && 
                uint32_t now = call neighborTimer.getNow();
                if(!hasNeighbor(p->src)){
                neighbors[numNeighbors] = p->src;
                lastHeard[numNeighbors] = now;
                numNeighbors++;
                dbg(NEIGHBOR_CHANNEL, "Neighbor Found: %d at time %d\n", p->src, lastHeard[numNeighbors - 1]);
                }
                else{   //update the last heard time
                    int i;
                    for(i=0; i < numNeighbors; i++){
                        if(neighbors[i] == p->src){
                            lastHeard[i] = now;
                            dbg(NEIGHBOR_CHANNEL, "Neighbor Updated: %d to time %d\n", p->src, lastHeard[i]);
                        }
                    }
                }
            }
        }
    }
    void maintainNeighbors(){
        int i;
        int j;
        uint32_t now = call neighborTimer.getNow();
        for(i = 0; i < numNeighbors; i++){
            if(now - lastHeard[i] > 15000){ //if we haven't heard from a neighbor in 15 seconds, remove it
                dbg(NEIGHBOR_CHANNEL, "Neighbor Lost: %d\n", neighbors[i]);
                //shift the array down
                for(j = i; j < numNeighbors - 1; j++){
                    neighbors[j] = neighbors[j + 1];
                    lastHeard[j] = lastHeard[j + 1];
                }
                numNeighbors--;
                i--; //check this index again since we shifted
            }
        }
    }

    command int NeighborDiscovery.getNeighbors(int num){
        return neighbors[num];
    }
    command int NeighborDiscovery.numNeighbors(){
        return numNeighbors;
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
      maintainNeighbors();
    }


    command void NeighborDiscovery.printNeighbors(){
        int i;
        for(i = 0; i < numNeighbors; i++){
            dbg(NEIGHBOR_CHANNEL, "Neighbor ID: %d\n", neighbors[i]);
        }
    }


}
