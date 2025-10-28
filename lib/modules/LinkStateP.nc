#include <Timer.h>
#include <string.h>
#include "../../includes/packet.h"
#include "../../includes/channels.h"

module LinkStateP {
  provides interface LinkState;
  uses interface NeighborDiscovery;
  uses interface Flooding;
  uses interface Timer<TMilli> as linkStateTimer;
}

implementation {
   enum {
      MAX_LS_NEIGHBORS = (PACKET_MAX_PAYLOAD_SIZE - 5) / sizeof(nx_uint16_t),
      MAX_LSDB_ENTRIES = 20
   };

   typedef struct {
      uint16_t origin;
      uint16_t seq;
      uint8_t  neighborCount;
      uint16_t neighbors[MAX_LS_NEIGHBORS];
   } linkstate_payload_t;

   pack lsp;
   uint16_t lsaSeq = 0;
   typedef struct {
      bool valid;
      linkstate_payload_t payload;
   } ls_entry_t;

   ls_entry_t lsdb[MAX_LSDB_ENTRIES];

   void fillPacket(pack *pkt, uint16_t src, uint16_t dest, uint16_t ttl,
                   uint8_t protocol, uint16_t seqNum,
                   uint8_t *payload, uint8_t length) {
      pkt->src = src;
      pkt->dest = dest;
      pkt->TTL = ttl;
      pkt->seq = seqNum;
      pkt->protocol = protocol;
      memcpy(pkt->payload, payload, length);
   }

   uint8_t buildLinkStatePayload(linkstate_payload_t *payload, uint16_t *seqOut) {
      uint8_t count;
      uint16_t seqNum;
      uint8_t i;

      count = call NeighborDiscovery.numNeighbors();
      if(count > MAX_LS_NEIGHBORS) {
         count = MAX_LS_NEIGHBORS;
      }

      seqNum = ++lsaSeq;
      payload->origin = TOS_NODE_ID;
      payload->seq = seqNum;
      payload->neighborCount = count;

      for(i = 0; i < count; i++) {
         payload->neighbors[i] = call NeighborDiscovery.getNeighbors(i);
      }

      if(seqOut != NULL) {
         *seqOut = seqNum;
      }

   return (uint8_t)(sizeof(payload->origin) +
                    sizeof(payload->seq) +
                    sizeof(payload->neighborCount) +
                    count * sizeof(payload->neighbors[0]));
}

   void storeLinkStatePayload(linkstate_payload_t *payload) {
      uint8_t freeIndex = MAX_LSDB_ENTRIES;
      uint8_t i;
      uint16_t newSeq = payload->seq;
      uint8_t newCount = payload->neighborCount;
      uint16_t newOrigin = payload->origin;

      for(i = 0; i < MAX_LSDB_ENTRIES; i++) {
         if(lsdb[i].valid) {
            if(lsdb[i].payload.origin == newOrigin) {
               if(newSeq <= lsdb[i].payload.seq) {
                  return;
               }
               lsdb[i].payload = *payload;
               dbg(FLOODING_CHANNEL, "LSDB update origin %u seq %u count %u\n",
                   newOrigin, newSeq, newCount);
               return;
            }
         } else if(freeIndex == MAX_LSDB_ENTRIES) {
            freeIndex = i;
         }
      }

      if(freeIndex < MAX_LSDB_ENTRIES) {
         lsdb[freeIndex].valid = TRUE;
         lsdb[freeIndex].payload = *payload;
         dbg(FLOODING_CHANNEL, "LSDB add origin %u seq %u count %u\n",
             newOrigin, newSeq, newCount);
      } else {
         dbg(FLOODING_CHANNEL, "LSDB full, dropping origin %u seq %u\n",
             newOrigin, newSeq);
      }
   }

   command void LinkState.init() {
      memset(lsdb, 0, sizeof(lsdb));
      call linkStateTimer.startPeriodic(10000);
   }

   event void linkStateTimer.fired() {
      linkstate_payload_t payload;
      uint16_t seqNum = 0;
      uint8_t payloadLen = buildLinkStatePayload(&payload, &seqNum);
      storeLinkStatePayload(&payload);

      fillPacket(&lsp,
                 TOS_NODE_ID,
                 AM_BROADCAST_ADDR,
                 MAX_TTL,
                 PROTOCOL_LINKEDSTATE,
                 seqNum,
                 (uint8_t *)&payload,
                 payloadLen);
      dbg(FLOODING_CHANNEL, "LSA seq %u count %u\n", seqNum,
          payload.neighborCount);

      call Flooding.floodPacket(&lsp);
   }

   command void LinkState.handleAdvertisement(pack *msg) {
      linkstate_payload_t incoming;

      if(msg == NULL) {
         return;
      }

      memset(&incoming, 0, sizeof(linkstate_payload_t));
      memcpy(&incoming, msg->payload, sizeof(linkstate_payload_t));

      storeLinkStatePayload(&incoming);
   }
}
