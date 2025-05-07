/*
 * MiracleCast - Wifi-Display/Miracast Implementation
 *
 * Copyright (c) 2013-2014 David Herrmann <dh.herrmann@gmail.com>
 *
 * MiracleCast is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * MiracleCast is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with MiracleCast; If not, see <http://www.gnu.org/licenses/>.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include "ctl.h"
#include "shl_log.h"
#include "shl_macro.h"

/* Source mode streaming configuration */
#define DEFAULT_SOURCE_PORT 8554
#define DEFAULT_FPS 30
#define DEFAULT_BITRATE 8192

/* Error codes for source mode */
#define SRC_ERR_NONE 0
#define SRC_ERR_ALREADY_RUNNING -1
#define SRC_ERR_INVALID_PARAMS -2
#define SRC_ERR_FORK_FAILED -3
#define SRC_ERR_EXEC_FAILED -4
#define SRC_ERR_NOT_RUNNING -5

struct ctl_source {
    pid_t stream_pid;
    char *target_address;
    int port;
    int fps;
    int bitrate;
    int width;
    int height;
    bool audio;
    /* Method selection */
    enum {
        STREAM_AUTO = 0,
        STREAM_GSTREAMER,
        STREAM_VLC,
        STREAM_FFMPEG
    } method;
    /* Last error code */
    int last_error;
    /* Last error message */
    char error_msg[256];
};

static struct ctl_source source = {
    .stream_pid = 0,
    .target_address = NULL,
    .port = DEFAULT_SOURCE_PORT,
    .fps = DEFAULT_FPS,
    .bitrate = DEFAULT_BITRATE,
    .width = 0,
    .height = 0,
    .audio = true,
    .method = STREAM_AUTO,
    .last_error = SRC_ERR_NONE,
    .error_msg = ""
};

static void kill_stream_process(void)
{
    if (source.stream_pid <= 0)
        return;

    kill(source.stream_pid, SIGTERM);
    source.stream_pid = 0;
    free(source.target_address);
    source.target_address = NULL;
}

/*
 * Launches a streaming process using GStreamer or VLC to stream the screen
 * to the sink device
 */
/**
 * Check if a command exists in the PATH
 */
static bool command_exists(const char *cmd)
{
    return (access(cmd, X_OK) == 0 || system(NULL) && !system(shl_strcat("which ", cmd, " > /dev/null")));
}

/**
 * Detect best available streaming method
 */
static int detect_streaming_method(void)
{
    if (source.method != STREAM_AUTO) {
        return source.method;
    }
    
    /* Check for GStreamer */
    if (command_exists("gst-launch-1.0")) {
        return STREAM_GSTREAMER;
    }
    
    /* Check for VLC */
    if (command_exists("cvlc") || command_exists("vlc")) {
        return STREAM_VLC;
    }
    
    /* Check for ffmpeg */
    if (command_exists("ffmpeg")) {
        return STREAM_FFMPEG;
    }
    
    /* Default to GStreamer anyway, it will fail in exec if not available */
    return STREAM_GSTREAMER;
}

/**
 * Get a string describing the current streaming method
 */
const char *get_streaming_method_name(int method)
{
    switch (method) {
        case STREAM_AUTO:
            return "auto-detect";
        case STREAM_GSTREAMER:
            return "GStreamer";
        case STREAM_VLC:
            return "VLC";
        case STREAM_FFMPEG:
            return "FFmpeg";
        default:
            return "unknown";
    }
}

/**
 * Start streaming to a target device
 */
int start_stream(const char *target_ip, int port, int width, int height, int fps, int bitrate, bool audio)
{
    pid_t pid;
    char port_str[16];
    char fps_str[16];
    char resolution[64];
    char bitrate_str[16];
    int streaming_method;
    
    /* Clear previous error state */
    source.last_error = SRC_ERR_NONE;
    source.error_msg[0] = '\0';
    
    if (source.stream_pid > 0) {
        snprintf(source.error_msg, sizeof(source.error_msg), 
                "Stream already running with PID %d, stop it first", 
                source.stream_pid);
        cli_error("%s", source.error_msg);
        source.last_error = SRC_ERR_ALREADY_RUNNING;
        return source.last_error;
    }
    
    if (!target_ip || !*target_ip) {
        snprintf(source.error_msg, sizeof(source.error_msg), "No target IP provided");
        cli_error("%s", source.error_msg);
        source.last_error = SRC_ERR_INVALID_PARAMS;
        return source.last_error;
    }
    
    /* Store parameters */
    source.target_address = strdup(target_ip);
    source.port = port ? port : DEFAULT_SOURCE_PORT;
    source.fps = fps ? fps : DEFAULT_FPS;
    source.bitrate = bitrate ? bitrate : DEFAULT_BITRATE;
    source.width = width;
    source.height = height;
    source.audio = audio;
    
    /* Format parameters for command line */
    sprintf(port_str, "%d", source.port);
    sprintf(fps_str, "%d", source.fps);
    sprintf(bitrate_str, "%d", source.bitrate);
    
    if (width && height)
        sprintf(resolution, "%dx%d", width, height);
    else
        sprintf(resolution, "auto");
    
    /* Detect which streaming method to use */
    streaming_method = detect_streaming_method();
    
    cli_printf("Using %s for streaming to %s:%d (resolution: %s, fps: %d, bitrate: %d)...\n",
              get_streaming_method_name(streaming_method),
              target_ip, source.port, resolution, source.fps, source.bitrate);
    
    pid = fork();
    if (pid < 0) {
        snprintf(source.error_msg, sizeof(source.error_msg), 
                "Failed to fork streaming process: %s", strerror(errno));
        cli_error("%s", source.error_msg);
        source.last_error = SRC_ERR_FORK_FAILED;
        return source.last_error;
    } else if (!pid) {
        /* child process */
        int fd_null;
        
        /* Make process leader of its own process group */
        setpgid(0, 0);
        
        /* Redirect stdout/stderr if not in debug mode */
        if (cli_max_sev < LOG_DEBUG) {
            fd_null = open("/dev/null", O_RDWR);
            if (fd_null >= 0) {
                dup2(fd_null, STDOUT_FILENO);
                dup2(fd_null, STDERR_FILENO);
                close(fd_null);
            }
        }
        
        /* Choose streaming method based on detection */
        switch (streaming_method) {
            case STREAM_GSTREAMER:
                /* GStreamer streaming pipeline */
                if (width && height) {
                    execlp("gst-launch-1.0", "gst-launch-1.0",
                        "ximagesrc", 
                        "!", shl_strcat("video/x-raw,framerate=", fps_str, "/1"),
                        "!", "videoconvert", 
                        "!", "videoscale",
                        "!", shl_strcat("video/x-raw,width=", width > 0 ? itoa(width) : "1280", 
                             ",height=", height > 0 ? itoa(height) : "720"),
                        "!", "videoconvert",
                        "!", "x264enc", "tune=zerolatency", shl_strcat("bitrate=", bitrate_str),
                        "!", "rtph264pay", 
                        "!", "udpsink", shl_strcat("host=", target_ip), shl_strcat("port=", port_str), 
                        "auto-multicast=true",
                        NULL);
                } else {
                    execlp("gst-launch-1.0", "gst-launch-1.0",
                        "ximagesrc", 
                        "!", shl_strcat("video/x-raw,framerate=", fps_str, "/1"),
                        "!", "videoconvert", 
                        "!", "x264enc", "tune=zerolatency", shl_strcat("bitrate=", bitrate_str),
                        "!", "rtph264pay", 
                        "!", "udpsink", shl_strcat("host=", target_ip), shl_strcat("port=", port_str), 
                        "auto-multicast=true",
                        NULL);
                }
                break;
                
            case STREAM_VLC:
                /* VLC streaming */
                {
                    char sout_opts[1024];
                    
                    if (width && height) {
                        snprintf(sout_opts, sizeof(sout_opts),
                            "#transcode{vcodec=h264,vb=%d,width=%d,height=%d,fps=%d,acodec=%s}:"
                            "rtp{dst=%s,port=%d,mux=ts}",
                            source.bitrate, width, height, source.fps, 
                            audio ? "mp3" : "none", target_ip, source.port);
                    } else {
                        snprintf(sout_opts, sizeof(sout_opts),
                            "#transcode{vcodec=h264,vb=%d,fps=%d,acodec=%s}:"
                            "rtp{dst=%s,port=%d,mux=ts}",
                            source.bitrate, source.fps, 
                            audio ? "mp3" : "none", target_ip, source.port);
                    }
                    
                    execlp("cvlc", "cvlc", "screen://", 
                        shl_strcat(":screen-fps=", fps_str),
                        ":screen-caching=100", 
                        "--sout", sout_opts,
                        NULL);
                }
                break;
                
            case STREAM_FFMPEG:
                /* FFmpeg streaming */
                {
                    if (width && height) {
                        execlp("ffmpeg", "ffmpeg", 
                            "-f", "x11grab", "-r", fps_str, "-i", ":0.0",
                            "-vf", shl_strcat("scale=", itoa(width), ":", itoa(height)),
                            "-vcodec", "libx264", "-preset", "ultrafast", 
                            "-tune", "zerolatency", "-b:v", shl_strcat(bitrate_str, "k"),
                            "-f", "rtp", shl_strcat("rtp://", target_ip, ":", port_str),
                            NULL);
                    } else {
                        execlp("ffmpeg", "ffmpeg", 
                            "-f", "x11grab", "-r", fps_str, "-i", ":0.0",
                            "-vcodec", "libx264", "-preset", "ultrafast", 
                            "-tune", "zerolatency", "-b:v", shl_strcat(bitrate_str, "k"),
                            "-f", "rtp", shl_strcat("rtp://", target_ip, ":", port_str),
                            NULL);
                    }
                }
                break;
        }

        /* If all streaming methods fail */
        snprintf(source.error_msg, sizeof(source.error_msg),
                "Failed to execute %s streaming: %s",
                get_streaming_method_name(streaming_method),
                strerror(errno));
        _exit(EXIT_FAILURE);
    }
    
    /* parent process */
    source.stream_pid = pid;
    cli_printf("Started screen streaming to %s:%d with PID %d\n", 
               target_ip, source.port, pid);
    
    return 0;
}

/*
 * Stop running stream
 */
int stop_stream(void)
{
    /* Clear previous error state */
    source.last_error = SRC_ERR_NONE;
    source.error_msg[0] = '\0';
    
    if (source.stream_pid <= 0) {
        snprintf(source.error_msg, sizeof(source.error_msg), "No stream is running");
        source.last_error = SRC_ERR_NOT_RUNNING;
        cli_info("%s", source.error_msg);
        return 0;
    }
    
    kill_stream_process();
    cli_printf("Stopped screen streaming\n");
    
    return 0;
}

/*
 * Get error message from last operation
 */
const char *get_source_error_message(void)
{
    return source.error_msg;
}

/*
 * Get error code from last operation
 */
int get_source_error_code(void)
{
    return source.last_error;
}

/*
 * Set streaming method (STREAM_AUTO, STREAM_GSTREAMER, etc.)
 */
void set_streaming_method(int method)
{
    source.method = method;
}

/*
 * Get current streaming status
 */
bool is_streaming_active(void)
{
    return (source.stream_pid > 0);
}

/*
 * Clean up resources on exit
 */
void source_cleanup(void)
{
    kill_stream_process();
}