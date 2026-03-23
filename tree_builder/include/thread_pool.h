/**
 * thread_pool.h - Generic Thread Pool
 * 
 * Provides a fixed-size thread pool with a work queue.
 * Uses POSIX threads (pthreads).
 */

#ifndef THREAD_POOL_H
#define THREAD_POOL_H

#include <stdbool.h>
#include <stddef.h>
#include <pthread.h>

/* Forward declaration */
typedef struct ThreadPool ThreadPool;

/* Task function signature */
typedef void (*TaskFunc)(void *arg);

/**
 * Create a thread pool
 * 
 * @param num_threads Number of worker threads
 * @return Thread pool, or NULL on failure
 */
ThreadPool* thread_pool_create(int num_threads);

/**
 * Destroy the thread pool
 * Waits for all pending tasks to complete first.
 * 
 * @param pool The pool to destroy
 */
void thread_pool_destroy(ThreadPool *pool);

/**
 * Submit a task to the pool
 * 
 * @param pool The thread pool
 * @param func Task function
 * @param arg Argument passed to task function
 * @return true on success, false if pool is shutting down
 */
bool thread_pool_submit(ThreadPool *pool, TaskFunc func, void *arg);

/**
 * Wait for all submitted tasks to complete
 * 
 * @param pool The thread pool
 */
void thread_pool_wait(ThreadPool *pool);

/**
 * Get the number of pending tasks
 * 
 * @param pool The thread pool
 * @return Number of tasks waiting + in progress
 */
int thread_pool_pending(ThreadPool *pool);

#endif /* THREAD_POOL_H */
