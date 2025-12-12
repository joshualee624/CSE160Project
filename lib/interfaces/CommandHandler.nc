interface CommandHandler{
   // Events
   event void ping(uint16_t destination, uint8_t *payload);
   event void printNeighbors();
   event void printRouteTable();
   event void printLinkState();
   event void printDistanceVector();
   event void setTestServer(uint8_t port);//originally left empty, added parameters because getting errors. 
   event void setTestClient(uint16_t dest, uint8_t srcPort, uint8_t destPort, uint16_t transfer); //originally left empty, added parameters because getting errors. 
   event void setAppServer();
   event void setAppClient();
   // serverAddr: node ID of the chat server (probably 1)
   // clientPort: local port for the client socket
   // username: pointer into the CommandMsg payload (null-terminated string)
   event void chatHello(uint8_t serverAddr, uint8_t clientPort, uint8_t *username);

   // message: pointer into payload (null-terminated string)
   event void chatMsg(uint8_t *message);

   // username + message: two null-terminated strings packed into payload
   event void chatWhisper(uint8_t *username, uint8_t *message);

   // no payload; just trigger the listusr behavior
   event void chatListusr();
}
