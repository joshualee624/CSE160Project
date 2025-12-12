/**
 * @author UCM ANDES Lab
 * $Author: abeltran2 $
 * $LastChangedDate: 2014-08-31 16:06:26 -0700 (Sun, 31 Aug 2014) $
 *
 */


#include "../../includes/CommandMsg.h"
#include "../../includes/command.h"
#include "../../includes/channels.h"

module CommandHandlerP{
   provides interface CommandHandler;
   uses interface Receive;
   uses interface Pool<message_t>;
   uses interface Queue<message_t*>;
   uses interface Packet;
}

implementation{
    task void processCommand(){
        if(! call Queue.empty()){
            CommandMsg *msg;
            uint8_t commandID;
            uint8_t* buff;
            message_t *raw_msg;
            void *payload;

            // Pop message out of queue.
            raw_msg = call Queue.dequeue();
            payload = call Packet.getPayload(raw_msg, sizeof(CommandMsg));

            // Check to see if the packet is valid.
            if(!payload){
                call Pool.put(raw_msg);
                post processCommand();
                return;
            }
            // Change it to our type.
            msg = (CommandMsg*) payload;

            dbg(COMMAND_CHANNEL, "A Command has been Issued.\n");
            buff = (uint8_t*) msg->payload;
            commandID = msg->id;

            //Find out which command was called and call related command
            switch(commandID){
            // A ping will have the destination of the packet as the first
            // value and the string in the remainder of the payload
            case CMD_PING:
                dbg(COMMAND_CHANNEL, "Command Type: Ping\n");
                signal CommandHandler.ping(buff[0], &buff[1]);
                break;

            case CMD_NEIGHBOR_DUMP:
                dbg(COMMAND_CHANNEL, "Command Type: Neighbor Dump\n");
                signal CommandHandler.printNeighbors();
                break;

            case CMD_LINKSTATE_DUMP:
                dbg(COMMAND_CHANNEL, "Command Type: Link State Dump\n");
                signal CommandHandler.printLinkState();
                break;

            case CMD_ROUTETABLE_DUMP:
                dbg(COMMAND_CHANNEL, "Command Type: Route Table Dump\n");
                signal CommandHandler.printRouteTable();
                break;

            case CMD_TEST_CLIENT: {
                uint16_t dest     = buff[0];   // 0–255, stored in 16-bit
                uint8_t  srcPort  = buff[1];
                uint8_t  destPort = buff[2];
                uint16_t transfer = buff[3];   // 0–255, since only 1 byte sent
                dbg(COMMAND_CHANNEL, "Command Type: Client (dest=%u, srcPort=%u, destPort=%u, transfer=%u)\n",
                    dest, srcPort, destPort, transfer);
                signal CommandHandler.setTestClient(dest, srcPort, destPort, transfer);
                break;
            }

            case CMD_TEST_SERVER: {
                uint8_t port = buff[0];
                dbg(COMMAND_CHANNEL, "Command Type: Server (port=%u)\n", port);
                signal CommandHandler.setTestServer(port);
                break;
            }
            case CMD_HELLO: {
                uint8_t serverAddr = buff[0];
                uint8_t clientPort = buff[1];
                uint8_t *username  = &buff[2];

                dbg(COMMAND_CHANNEL,
                    "Command Type: CHAT HELLO (server=%hhu, clientPort=%hhu, username=%s)\n",
                    serverAddr, clientPort, username);

                signal CommandHandler.chatHello(serverAddr, clientPort, username);
                break;
            }
            case CMD_MSG: {
            // Whole payload is the message string
                uint8_t *message = buff;

                dbg(COMMAND_CHANNEL,
                    "Command Type: CHAT MSG (%s)\n", message);

                signal CommandHandler.chatMsg(message);
                break;
            }
            case CMD_WHISPER: {
                uint8_t *userPtr = buff;
                uint8_t *msgPtr  = buff;
                uint8_t i;

                // Find separator 0 between username and message
                for (i = 0; i < 25; i++) {   // 25 = CommandMsg payload length
                    if (msgPtr[i] == 0) {
                        msgPtr = &msgPtr[i + 1];   // start of message
                        break;
                    }
                }

                dbg(COMMAND_CHANNEL,
                    "Command Type: CHAT WHISPER (user=%s, msg=%s)\n",
                    userPtr, msgPtr);

                signal CommandHandler.chatWhisper(userPtr, msgPtr);
                break;
            }
            case CMD_LISTUSR: {
                dbg(COMMAND_CHANNEL, "Command Type: CHAT LISTUSR\n");
                signal CommandHandler.chatListusr();
                break;
            }
            case CMD_SET_APP_SERVER: {
                dbg(COMMAND_CHANNEL, "Command Type: CHAT SET_APP_SERVER\n");
                signal CommandHandler.setAppServer();
                break;
            }
            case CMD_SET_APP_CLIENT: {
                dbg(COMMAND_CHANNEL, "Command Type: CHAT SET_APP_CLIENT\n");
                signal CommandHandler.setAppClient();
                break;
            }


            default:
                dbg(COMMAND_CHANNEL, "CMD_ERROR: \"%d\" does not match any known commands.\n", msg->id);
                break;
            }
            call Pool.put(raw_msg);
        }

        if(! call Queue.empty()){
            post processCommand();
        }
    }
    event message_t* Receive.receive(message_t* raw_msg, void* payload, uint8_t len){
        if (! call Pool.empty()){
            call Queue.enqueue(raw_msg);
            post processCommand();
            return call Pool.get();
        }
        return raw_msg;
    }
}
