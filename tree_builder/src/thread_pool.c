/**
 * thread_pool.c - Generic Thread Pool Implementation
 * 
 * Uses POSIX threads with a mutex-protected work queue
 * and condition variables for synchronization.
 */

#include "thread_pool.h"
#include <stdlib.h>
#include <stdio.h>

/* Task node for the linked-list queue */
typedef struct TaskNode {
    TaskFunc func;
    void *arg;
    struct TaskNode *next;
} TaskNode;

/* Thread pool structure */
struct ThreadPool {
    pthread_t *threads;
    int num_threads;
    
    /* Work queue (linked list) */
    TaskNode *queue_head;
    TaskNode *queue_tail;
    int queue_size;
    
    /* Synchronization */
    pthread_mutex_t mutex;
    pthread_cond_t work_available;  /* Signal: new work in queue */
    pthread_cond_t work_done;       /* Signal: a task finished */
    
    /* State */
    int active_tasks;               /* Tasks currently being executed */
    bool shutdown;                  /* Pool is shutting down */
};


/**
 * Worker thread function
 */
static void* worker_func(void *arg) {
    ThreadPool *pool = (ThreadPool *)arg;
    
    while (1) {
        pthread_mutex_lock(&pool->mutex);
        
        /* Wait for work or shutdown */
        while (pool->queue_size == 0 && !pool->shutdown) {
            pthread_cond_wait(&pool->work_available, &pool->mutex);
        }
        
        if (pool->shutdown && pool->queue_size == 0) {
            pthread_mutex_unlock(&pool->mutex);
            break;
        }
        
        /* Dequeue a task */
        TaskNode *task = pool->queue_head;
        if (task) {
            pool->queue_head = task->next;
            if (!pool->queue_head) {
                pool->queue_tail = NULL;
            }
            pool->queue_size--;
            pool->active_tasks++;
        }
        
        pthread_mutex_unlock(&pool->mutex);
        
        /* Execute the task */
        if (task) {
            task->func(task->arg);
            free(task);
            
            pthread_mutex_lock(&pool->mutex);
            pool->active_tasks--;
            /* Signal that a task is done (for thread_pool_wait) */
            if (pool->active_tasks == 0 && pool->queue_size == 0) {
                pthread_cond_broadcast(&pool->work_done);
            }
            pthread_mutex_unlock(&pool->mutex);
        }
    }
    
    return NULL;
}


ThreadPool* thread_pool_create(int num_threads) {
    if (num_threads <= 0) return NULL;
    
    ThreadPool *pool = (ThreadPool *)calloc(1, sizeof(ThreadPool));
    if (!pool) return NULL;
    
    pool->num_threads = num_threads;
    pool->queue_head = NULL;
    pool->queue_tail = NULL;
    pool->queue_size = 0;
    pool->active_tasks = 0;
    pool->shutdown = false;
    
    pthread_mutex_init(&pool->mutex, NULL);
    pthread_cond_init(&pool->work_available, NULL);
    pthread_cond_init(&pool->work_done, NULL);
    
    pool->threads = (pthread_t *)calloc(num_threads, sizeof(pthread_t));
    if (!pool->threads) {
        free(pool);
        return NULL;
    }
    
    /* Create worker threads */
    for (int i = 0; i < num_threads; i++) {
        if (pthread_create(&pool->threads[i], NULL, worker_func, pool) != 0) {
            fprintf(stderr, "Error: Failed to create thread %d\n", i);
            /* Clean up already-created threads */
            pool->shutdown = true;
            pthread_cond_broadcast(&pool->work_available);
            for (int j = 0; j < i; j++) {
                pthread_join(pool->threads[j], NULL);
            }
            free(pool->threads);
            free(pool);
            return NULL;
        }
    }
    
    return pool;
}


void thread_pool_destroy(ThreadPool *pool) {
    if (!pool) return;
    
    /* Signal shutdown */
    pthread_mutex_lock(&pool->mutex);
    pool->shutdown = true;
    pthread_cond_broadcast(&pool->work_available);
    pthread_mutex_unlock(&pool->mutex);
    
    /* Wait for all threads to finish */
    for (int i = 0; i < pool->num_threads; i++) {
        pthread_join(pool->threads[i], NULL);
    }
    
    /* Free remaining tasks in queue */
    TaskNode *current = pool->queue_head;
    while (current) {
        TaskNode *next = current->next;
        free(current);
        current = next;
    }
    
    /* Cleanup */
    pthread_mutex_destroy(&pool->mutex);
    pthread_cond_destroy(&pool->work_available);
    pthread_cond_destroy(&pool->work_done);
    free(pool->threads);
    free(pool);
}


bool thread_pool_submit(ThreadPool *pool, TaskFunc func, void *arg) {
    if (!pool || !func) return false;
    
    TaskNode *task = (TaskNode *)malloc(sizeof(TaskNode));
    if (!task) return false;
    
    task->func = func;
    task->arg = arg;
    task->next = NULL;
    
    pthread_mutex_lock(&pool->mutex);
    
    if (pool->shutdown) {
        pthread_mutex_unlock(&pool->mutex);
        free(task);
        return false;
    }
    
    /* Enqueue */
    if (pool->queue_tail) {
        pool->queue_tail->next = task;
    } else {
        pool->queue_head = task;
    }
    pool->queue_tail = task;
    pool->queue_size++;
    
    /* Signal a worker */
    pthread_cond_signal(&pool->work_available);
    
    pthread_mutex_unlock(&pool->mutex);
    
    return true;
}


void thread_pool_wait(ThreadPool *pool) {
    if (!pool) return;
    
    pthread_mutex_lock(&pool->mutex);
    while (pool->queue_size > 0 || pool->active_tasks > 0) {
        pthread_cond_wait(&pool->work_done, &pool->mutex);
    }
    pthread_mutex_unlock(&pool->mutex);
}


int thread_pool_pending(ThreadPool *pool) {
    if (!pool) return 0;
    
    pthread_mutex_lock(&pool->mutex);
    int total = pool->queue_size + pool->active_tasks;
    pthread_mutex_unlock(&pool->mutex);
    
    return total;
}
