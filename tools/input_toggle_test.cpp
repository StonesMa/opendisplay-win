// Tests the production injector with synthetic-input APIs replaced by recorders.
// No touch, pen or mouse events reach the desktop.
#include <windows.h>
#include <atomic>
#include <cassert>
#include <cstdio>
#include <thread>
#include <vector>

static std::vector<POINTER_TYPE_INFO> events;
static unsigned wheels = 0;
static unsigned devices = 0;

HSYNTHETICPOINTERDEVICE WINAPI TestCreate(POINTER_INPUT_TYPE, ULONG, POINTER_FEEDBACK_MODE)
{
    ++devices;
    return reinterpret_cast<HSYNTHETICPOINTERDEVICE>(static_cast<UINT_PTR>(devices));
}
BOOL WINAPI TestInject(HSYNTHETICPOINTERDEVICE, const POINTER_TYPE_INFO* info, UINT32 count)
{
    events.insert(events.end(), info, info + count);
    return TRUE;
}
void WINAPI TestDestroy(HSYNTHETICPOINTERDEVICE) {}
UINT WINAPI TestSendInput(UINT count, LPINPUT, int) { wheels += count; return count; }
int WINAPI TestMetrics(int) { return 0; }

#define CreateSyntheticPointerDevice TestCreate
#define InjectSyntheticPointerInput TestInject
#define DestroySyntheticPointerDevice TestDestroy
#define SendInput TestSendInput
#define GetSystemMetrics TestMetrics
#include "../src/input/InputInjector.cpp"

int main()
{
    using namespace od;
    InputInjector input;
    input.SetMonitorRect({0, 0, 1920, 1080});
    input.SetEnabled(false);
    input.HandleTouch({TouchPhase::Began, .5, .5, 1});
    input.HandleScroll({100, 100});
    input.HandlePencil({PencilPhase::Down, .5, .5, 1});
    input.HandleProximity({true, .5, .5});
    assert(events.empty() && wheels == 0 && devices == 0);
    std::puts("PASS: disabled touch, pen, hover and scroll inject nothing");

    input.SetEnabled(true);
    input.HandleTouch({TouchPhase::Moved, .5, .5, 1});
    assert(events.empty());
    input.HandleTouch({TouchPhase::Ended, .5, .5, 1});
    input.HandleTouch({TouchPhase::Began, .5, .5, 1});
    input.HandleTouch({TouchPhase::Began, .6, .6, 2});
    input.HandlePencil({PencilPhase::Down, .5, .5, 1});
    input.HandleScroll({100, 0});
    assert(wheels == 1 && !events.empty());
    const auto beforeDisable = events.size();
    input.SetEnabled(false);
    unsigned touchUps = 0, penUps = 0;
    for (size_t i = beforeDisable; i < events.size(); ++i) {
        const auto& e = events[i];
        if (e.type == PT_TOUCH && (e.touchInfo.pointerInfo.pointerFlags & POINTER_FLAG_UP)) ++touchUps;
        if (e.type == PT_PEN && (e.penInfo.pointerInfo.pointerFlags & POINTER_FLAG_UP)) ++penUps;
    }
    assert(touchUps == 2 && penUps == 1);
    const auto afterDisable = events.size();
    input.SetEnabled(false);
    assert(events.size() == afterDisable);
    std::puts("PASS: disabling immediately releases every active touch and pen once");

    input.SetEnabled(true);
    input.HandleTouch({TouchPhase::Moved, .7, .7, 1});
    input.HandleTouch({TouchPhase::Cancelled, .7, .7, 2});
    input.HandlePencil({PencilPhase::Move, .7, .7, 1});
    assert(events.size() == afterDisable);
    input.HandleTouch({TouchPhase::Began, .7, .7, 1});
    assert(events.size() > afterDisable);
    input.EndSession();
    std::puts("PASS: held contacts do not resume until a fresh touch or pen down");

    input.SetEnabled(false);
    input.EndSession();
    const auto beforeReconnect = events.size();
    input.HandleTouch({TouchPhase::Began, .5, .5, 1});
    assert(events.size() == beforeReconnect);
    std::puts("PASS: session cleanup does not reset the disabled policy");

    std::thread toggle([&] { for (int i=0; i<1000; ++i) input.SetEnabled((i%2)==0); });
    std::thread receive([&] {
        for (int i=0; i<1000; ++i) {
            input.HandleTouch({TouchPhase::Began, .5, .5, 1});
            input.HandleScroll({0, 100});
            input.HandleTouch({TouchPhase::Ended, .5, .5, 1});
        }
    });
    toggle.join();
    receive.join();
    input.SetEnabled(false);
    std::puts("PASS: tray toggles and receiver input can run concurrently");
}
