#include "opt-sched/Scheduler/utilities.h"
#include <chrono>

namespace opt_sched {
std::chrono::high_resolution_clock::time_point Utilities::startTime =
    std::chrono::high_resolution_clock::now();
}
