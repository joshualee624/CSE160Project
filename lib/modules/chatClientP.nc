// ChatClientP.nc
#include "../../includes/channels.h"
#include "../../includes/Transport.h"   // or correct path to your transport header

module ChatClientP {
  uses {
    interface Transport;   // your custom transport interface
  }
  provides {
    interface ChatClient;
  }
}
implementation {
  socket_t clientSock = NULL_SOCKET;
  bool connected = FALSE;

  command void ChatClient.hello(uint8_t serverAddr, uint8_t clientPort, char* username) {
    socketaddr_t dest;

    dest.addr = serverAddr;
    dest.port = 41;       // Chat server port from spec

    dbg(TRANSPORT_CHANNEL, "ChatClient: hello to server %hhu from port %hhu as %s\n",
        serverAddr, clientPort, username);

    clientSock = call Transport.socket();
    if (clientSock == NULL_SOCKET) {
      dbg(TRANSPORT_CHANNEL, "ChatClient: no socket available\n");
      return;
    }

    call Transport.bind(clientSock, clientPort);
    call Transport.connect(clientSock, &dest);

    // For now, send hello immediately. If your transport has a "connect complete"
    // event, you can move this there.
    sendHelloString(username);
  }

  void sendHelloString(char* username) {
    char buf[32];
    uint8_t len;

    // hello [username]\r\n
    len = snprintf(buf, sizeof buf, "hello %s\r\n", username);
    dbg(TRANSPORT_CHANNEL, "ChatClient: sending '%s'\n", buf);
    call Transport.write(clientSock, (uint8_t*)buf, len);
  }

  command void ChatClient.sendMsg(char* message) {
    char buf[64];
    uint8_t len;

    len = snprintf(buf, sizeof buf, "msg %s\r\n", message);
    dbg(TRANSPORT_CHANNEL, "ChatClient: msg '%s'\n", buf);
    call Transport.write(clientSock, (uint8_t*)buf, len);
  }

  command void ChatClient.whisper(char* username, char* message) {
    char buf[64];
    uint8_t len;

    len = snprintf(buf, sizeof buf, "whisper %s %s\r\n", username, message);
    dbg(TRANSPORT_CHANNEL, "ChatClient: whisper '%s'\n", buf);
    call Transport.write(clientSock, (uint8_t*)buf, len);
  }

  command void ChatClient.listUsers() {
    char buf[16] = "listusr\r\n";
    dbg(TRANSPORT_CHANNEL, "ChatClient: listusr\n");
    call Transport.write(clientSock, (uint8_t*)buf, 9); // strlen("listusr\r\n") == 9
  }

  // If your Transport interface has events like dataReceived, you’d also implement
  // them here to print out what the server sends back.
}
