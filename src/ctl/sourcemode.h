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

#ifndef CTL_SOURCEMODE_H
#define CTL_SOURCEMODE_H

#include <stdbool.h>

/* Error codes for source mode */
#define SRC_ERR_NONE 0
#define SRC_ERR_ALREADY_RUNNING -1
#define SRC_ERR_INVALID_PARAMS -2
#define SRC_ERR_FORK_FAILED -3
#define SRC_ERR_EXEC_FAILED -4
#define SRC_ERR_NOT_RUNNING -5

/* Streaming methods */
#define STREAM_AUTO 0
#define STREAM_GSTREAMER 1
#define STREAM_VLC 2
#define STREAM_FFMPEG 3

/* Start streaming to the target IP */
int start_stream(const char *target_ip, int port, int width, int height, int fps, int bitrate, bool audio);

/* Stop active streaming */
int stop_stream(void);

/* Error handling */
const char *get_source_error_message(void);
int get_source_error_code(void);

/* Configuration */
void set_streaming_method(int method);

/* Status */
bool is_streaming_active(void);

/* Cleanup */
void source_cleanup(void);

#endif /* CTL_SOURCEMODE_H */