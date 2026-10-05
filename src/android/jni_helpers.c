#include <jni.h>

const char *sudoku_jstring_utf_chars(void *env_ptr, void *jstr_ptr) {
  if (env_ptr == 0 || jstr_ptr == 0) return 0;
  JNIEnv *env = (JNIEnv *)env_ptr;
  jstring jstr = (jstring)jstr_ptr;
  return (*env)->GetStringUTFChars(env, jstr, 0);
}

void sudoku_release_jstring_utf_chars(void *env_ptr, void *jstr_ptr, const char *chars) {
  if (env_ptr == 0 || jstr_ptr == 0 || chars == 0) return;
  JNIEnv *env = (JNIEnv *)env_ptr;
  jstring jstr = (jstring)jstr_ptr;
  (*env)->ReleaseStringUTFChars(env, jstr, chars);
}
