/* Stop before any card, socket or thread work; detect upstream side effects. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

pid_t fork(void) {
  _exit(81);
}

FILE *fopen(const char *path, const char *mode) {
  if (strcmp(path, "/etc/hosts") == 0) {
    _exit(82);
  }
  FILE *(*real_fopen)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen");
  return real_fopen(path, mode);
}

int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*start)(void *), void *arg) {
  (void)thread;
  (void)attr;
  (void)start;
  (void)arg;
  /* Success means foreground main reached service initialization. */
  _exit(0);
}
