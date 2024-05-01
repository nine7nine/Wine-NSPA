#!/bin/bash

# Check if the folder path is provided as a command-line argument
if [ $# -ne 1 ]; then
    echo "Usage: $0 <folder_path>"
    exit 1
fi

# Assign the folder path provided as a command-line argument
FOLDER="$1"

# Remove pthread_mutex_init in .c and .h files recursively
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i '/pthread_mutex_init/d' {} +
# Replace pthread_mutex_lock with pi_mutex_lock in .c and .h files recursively
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/pthread_mutex_lock/pi_mutex_lock/g' {} +
# Replace pthread_mutex_unlock with pi_mutex_unlock in .c and .h files recursively
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/pthread_mutex_unlock/pi_mutex_unlock/g' {} +
# Replace pthread_mutex_destroy with pi_mutex_destroy in .c and .h files recursively
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/pthread_mutex_destroy/pi_mutex_destroy/g' {} +
# Replace PTHREAD_MUTEX_INITIALIZER with PI_MUTEX_INIT in .c and .h files recursively
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/PTHREAD_MUTEX_INITIALIZER/PI_MUTEX_INIT(0)/g' {} +

# Add #include <rtpi.h> after #include <pthread.h> in .c and .h files recursively
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i '/#include <pthread.h>/a #include <rtpi.h>' {} +

# Update Mutex Definitions: Replace pthread_mutex_t with pi_mutex_t
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/pthread_mutex_t/pi_mutex_t/g' {} +

# Remove lines containing pthread_mutexattr_t functions
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i '/pthread_mutexattr_init/d' {} +
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i '/pthread_mutexattr_settype/d' {} +
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i '/pthread_mutexattr_destroy/d' {} +
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i '/pthread_mutexattr_t/d' {} +
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i '/pthread_mutexattr_setprotocol/d' {} +

# Replace pi_mutex_init( &mutex, &attr ) with pi_mutex_init(mutex, 0)
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/pi_mutex_init( &\([a-zA-Z0-9_]*\), &attr )/pi_mutex_init(\1, 0)/g' {} +

# Replace PTHREAD_COND_INITIALIZER with PI_COND_INIT in .c and .h files recursively
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/PTHREAD_COND_INITIALIZER/PI_COND_INIT(0)/g' {} +

# Replace pthread_cond_* with pi_cond_* and pthread_cond_t with pi_cond_t
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/pthread_cond_/pi_cond_/g' {} +
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/pthread_cond_t/pi_cond_t/g' {} +

# Remove the second argument (mutex) from calls to pi_cond_signal
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/pi_cond_signal( &\([a-zA-Z0-9_]*\) )/pi_cond_signal(\1)/g' {} +

# Replace pi_cond_init( &mutex, &attr ) with pi_cond_init(mutex, 0)
find "$FOLDER" \( -name "*.c" -o -name "*.h" \) -exec sed -i 's/pi_cond_init( &\([a-zA-Z0-9_]*\), &attr )/pi_cond_init(\1, 0)/g' {} +

# Update Makefile.in files to include -lrtpi if they contain "$(PTHREAD_LIBS)"
find "$FOLDER" -name "Makefile.in" -exec sed -i '/$(PTHREAD_LIBS)/s/$/ -lrtpi/' {} +
