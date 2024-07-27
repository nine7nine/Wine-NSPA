#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    int test_id;
    int thread_id;
    int count;
    LARGE_INTEGER start_time;
    LARGE_INTEGER end_time;
    LARGE_INTEGER frequency;
    int duration;
} ThreadData;

DWORD WINAPI MutexTest(LPVOID param) {
    ThreadData* data = (ThreadData*)param;
    int count = 0;
    double elapsed_time;

    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);

    QueryPerformanceFrequency(&data->frequency);
    QueryPerformanceCounter(&data->start_time);

    while (1) {
        HANDLE hMutex = CreateMutex(NULL, FALSE, NULL);
        if (hMutex) {
            CloseHandle(hMutex);
            count++;
        }

        for (int i = 0; i < 1000; i++) {
            volatile int temp = i * i;  // Prevents compiler optimization
        }

        QueryPerformanceCounter(&data->end_time);
        elapsed_time = (double)(data->end_time.QuadPart - data->start_time.QuadPart) / data->frequency.QuadPart;
        if (elapsed_time >= data->duration) { // Stop after specified duration
            break;
        }
    }

    data->count = count;
    return 0;
}

void show_results(const char *message) {
    MessageBox(NULL, message, "Test Results", MB_OK | MB_ICONINFORMATION);
}

int main(int argc, char* argv[]) {
    if (argc != 4) {
        MessageBox(NULL, "Usage: mutex_test.exe <threads> <tests> <seconds>", "Error", MB_OK | MB_ICONERROR);
        return 1;
    }

    int numThreads = atoi(argv[1]);
    int numTests = atoi(argv[2]);
    int duration = atoi(argv[3]);

    if (numThreads <= 0 || numTests <= 0 || duration <= 0) {
        MessageBox(NULL, "Invalid arguments specified.", "Error", MB_OK | MB_ICONERROR);
        return 1;
    }

    SetPriorityClass(GetCurrentProcess(), REALTIME_PRIORITY_CLASS);

    char results[2048] = {0};
    size_t offset = 0;

    for (int test = 0; test < numTests; test++) {
        HANDLE* threads = malloc(numThreads * sizeof(HANDLE));
        ThreadData* thread_data = malloc(numThreads * sizeof(ThreadData));

        if (threads == NULL || thread_data == NULL) {
            MessageBox(NULL, "Failed to allocate memory for threads or thread data.", "Error", MB_OK | MB_ICONERROR);
            exit(1);
        }

        for (int i = 0; i < numThreads; i++) {
            thread_data[i].test_id = test;
            thread_data[i].thread_id = i;
            thread_data[i].duration = duration;

            threads[i] = CreateThread(NULL, 0, MutexTest, &thread_data[i], 0, NULL);
            if (threads[i] == NULL) {
                char error_message[256];
                snprintf(error_message, sizeof(error_message), "Failed to create thread %d for test %d. Error: %lu\n", i, test, GetLastError());
                MessageBox(NULL, error_message, "Error", MB_OK | MB_ICONERROR);
                for (int j = 0; j < i; j++) {
                    CloseHandle(threads[j]);
                }
                free(threads);
                free(thread_data);
                exit(1);
            }
        }

        WaitForMultipleObjects(numThreads, threads, TRUE, INFINITE);

        int total_count = 0;
        for (int i = 0; i < numThreads; i++) {
            total_count += thread_data[i].count;
            CloseHandle(threads[i]);
        }

        int written = snprintf(results + offset, sizeof(results) - offset, "Test: %d threads: %d mutexes: %d seconds: %d\n", test, numThreads, total_count, duration);
        if (written > 0) {
            offset += written;
        }

        free(threads);
        free(thread_data);
    }

    show_results(results);

    return 0;
}

