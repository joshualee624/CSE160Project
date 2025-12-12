// ChatClient.nc
interface ChatClient {
  // Open TCP connection to chat server and send hello username\r\n
  command void hello(uint8_t serverAddr, uint8_t clientPort, char* username);

  // Send a broadcast chat message: msg [message]\r\n
  command void sendMsg(char* message);

  // Send a whisper: whisper [username] [message]\r\n
  command void whisper(char* username, char* message);

  // Send listusr\r\n
  command void listUsers();
}

