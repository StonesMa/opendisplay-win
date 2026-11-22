#include "app/Config.h"
#include <cassert>
#include <cstdlib>
#include <cstdio>

int main(int argc, char** argv)
{
    assert(argc == 2);
    _putenv_s("APPDATA", argv[1]);
    auto cfg = od::Config::Load();
    assert(!cfg.disableReceiverInput);
    cfg.devices = {"192.168.1.42 Tablet"};
    cfg.deviceIds = {"test-device"};
    cfg.disableReceiverInput = true;
    cfg.Save();
    auto saved = od::Config::Load();
    assert(saved.disableReceiverInput);
    assert(saved.devices == cfg.devices && saved.deviceIds == cfg.deviceIds);
    saved.disableReceiverInput = false;
    saved.Save();
    assert(!od::Config::Load().disableReceiverInput);
    std::puts("PASS: input policy persists both ways and retains receiver identity");
}
