// Fairy-Stockfish's Position needs a Thread for counters, not a native search
// thread. The entire engine is already isolated in one browser Web Worker.
#include "Fairy-Stockfish/src/thread.h"

namespace Stockfish {
ThreadPool Threads;
Thread::Thread(size_t n) : idx(n) {}
Thread::~Thread() = default;
void Thread::search() {}
void MainThread::search() {}
void Thread::clear() {}
void Thread::start_searching() {}
void Thread::wait_for_search_finished() {}
void Thread::idle_loop() {}
void ThreadPool::set(size_t requested) {
    for (auto thread : *this) delete thread;
    clear();
    if (requested) push_back(new MainThread(0));
}
void ThreadPool::clear() { std::vector<Thread*>::clear(); }
}
