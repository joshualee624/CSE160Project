#include "../../includes/packet.h"

interface LinkState {
   command void init();
   command void handleAdvertisement(pack *msg);
}
