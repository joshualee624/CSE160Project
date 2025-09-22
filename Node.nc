/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

module Node{
   uses interface Boot;

   uses interface SplitControl as AMControl;
   uses interface Receive;

   uses interface SimpleSend as Sender;

   uses interface CommandHandler;
}

implementation{
   pack sendPackage;

//this will give unique packets source address and sequence number in order to
// not infinelty loop and re "use" packets we've seen befire
   enum {MAX_SEEN_PACKETS = 100 };
   typedef struct {
      uint16_t src;
      uint16_t seq;
   } seen_packet_t;

//stores alreadyseen packets in this array
   seen_packet_t seenPackets[MAX_SEEN_PACKETS];
   uint16_t seenPacketIndex = 0;
   uint16_t sequenceNumber = 0;

   // Prototypes
   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);
   bool hasSeenPacket(uint16_t src, uint16_t seq);
   void addSeenPacket(uint16_t src, uint16_t seq);
   void addNeighbor(uint16_t nodeId);


   event void Boot.booted(){
      call AMControl.start();
      dbg(GENERAL_CHANNEL, "Booted\n");
   }

   event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
         dbg(GENERAL_CHANNEL, "Radio On\n");
      }else{
         // Retry until successful
         call AMControl.start();
      }
   }

   event void AMControl.stopDone(error_t err){}

   void addNeighbor(uint16_t nodeId){
      dbg(NEIGHBOR_CHANNEL, "Adding neighbor %d\n", nodeId);
   }

   event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
      if (len == sizeof(pack)){
         pack* myMsg = (pack*) payload;

         dbg(FLOODING_CHANNEL, "Packet received at Node %d from %d\n", TOS_NODE_ID, myMsg->src);

         // Check TTL - drop if expired
         if(myMsg->TTL == 0){
            dbg(FLOODING_CHANNEL, "Packet dropped - TTL expired\n");
            return msg;
         }

         // Check if we've seen this packet before (loop prevention)
         if(hasSeenPacket(myMsg->src, myMsg->seq)){
            dbg(FLOODING_CHANNEL, "Packet dropped, already seen (src:%d, seq:%d)\n", myMsg->src, myMsg->seq);
            return msg;
         }
         addSeenPacket(myMsg->src, myMsg->seq);

         //this will check if the packet is for the correct node with the node id
         //
         if(myMsg->dest == TOS_NODE_ID){
            dbg (GENERAL_CHANNEL, "Packet for me. Payload: %s\n", myMsg->payload);

            switch(myMsg->protocol){
               case PROTOCOL_PING:
                  dbg(GENERAL_CHANNEL, "Ping received from %d\n", myMsg->src);
                  // send the ping reply
                  makePack(&sendPackage, TOS_NODE_ID, myMsg->src, MAX_TTL, PROTOCOL_PINGREPLY, sequenceNumber++, (uint8_t*)"ping reply", PACKET_MAX_PAYLOAD_SIZE);
                  call Sender.send(sendPackage, AM_BROADCAST_ADDR);
                  dbg(FLOODING_CHANNEL, "Ping reply sent from Node %d\n", TOS_NODE_ID);
                  break;

               case PROTOCOL_PINGREPLY:
                  dbg(GENERAL_CHANNEL, "Ping reply received from %d\n", myMsg->src);
                  addNeighbor(myMsg->src);
                  break;
                  
               default:
                  dbg(GENERAL_CHANNEL, "Unknown protocol: %d\n", myMsg->protocol);
                  break;
            }
         }
         //if the node and packet dest dont match flood the packet so it reaches the correct node
         else if(myMsg->dest != TOS_NODE_ID){
            pack floodPacket;
            
            // Flood the packet (decrement TTL)
            floodPacket = *myMsg;
            floodPacket.TTL--;
            //since the ttl is 15, this allows 15 hops so node 16 would jus recive with a ttl of 1, decrement = 0
            //so it would drop it
            //memory wont overflow and helps with inf loop in earlier note
            if(floodPacket.TTL > 0){
               call Sender.send(floodPacket, AM_BROADCAST_ADDR);
               dbg(FLOODING_CHANNEL, "Packet flooded from Node %d (TTL:%d)\n", TOS_NODE_ID, floodPacket.TTL);
            } else {
               dbg(FLOODING_CHANNEL, "Packet not flooded - TTL would be 0\n");
            }
         }
         
         return msg;
      }

      dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
      return msg;
   }

//makes the packet within all the parameters for the message
//having broadcast will send to all directly connected neighbors
//
   event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
      dbg(GENERAL_CHANNEL, "PING EVENT - sending to %d\n", destination);
      makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING, sequenceNumber++, payload, PACKET_MAX_PAYLOAD_SIZE);
      call Sender.send(sendPackage, AM_BROADCAST_ADDR);
      dbg(FLOODING_CHANNEL, "Ping sent from Node %d to %d\n", TOS_NODE_ID, destination);
   }


//goes through the packets stored and compares the seq and source address number
//

   bool hasSeenPacket(uint16_t src, uint16_t seq){
      uint16_t i;
      for(i = 0; i < MAX_SEEN_PACKETS && i < seenPacketIndex; i++){
         if(seenPackets[i].src == src && seenPackets[i].seq == seq){
            return TRUE;
         }
      }
      return FALSE;
   }  
//since the limit is 100 packets, once the i hit the limit of packets it it
//jus overwrite the old ones
//if the packet is seen as a dupliocate true then it will be dropped
   void addSeenPacket(uint16_t src, uint16_t seq){
      seenPackets[seenPacketIndex % MAX_SEEN_PACKETS].src = src;
      seenPackets[seenPacketIndex % MAX_SEEN_PACKETS].seq = seq;
      seenPacketIndex++;
   }

   void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
      Package->src = src;
      Package->dest = dest;
      Package->TTL = TTL;
      Package->seq = seq;
      Package->protocol = protocol;
      memcpy(Package->payload, payload, length);
   }

   event void CommandHandler.printNeighbors(){}

   event void CommandHandler.printRouteTable(){}

   event void CommandHandler.printLinkState(){}

   event void CommandHandler.printDistanceVector(){}

   event void CommandHandler.setTestServer(){}

   event void CommandHandler.setTestClient(){}

   event void CommandHandler.setAppServer(){}

   event void CommandHandler.setAppClient(){}
}