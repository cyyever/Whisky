/*
 * VideoToolbox regression probe: encode twelve known red NV12 frames,
 * autoplug a decoder, and check every decoded RGBA pixel.
 * --software disables the VideoToolbox decoder ranks only in this process.
 * --mp4 adds MP4 mux/demux before autoplugging the hardware decoder.
 * A 30-second alarm bounds initialization and pipeline teardown too.
 */
#import <Cocoa/Cocoa.h>
#include <gst/gst.h>
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static gint selected_decoder;

static void element_added(GstBin *bin, GstElement *element, gpointer unused)
{
    GstElementFactory *factory = gst_element_get_factory(element);
    const char *name = factory ? gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(factory)) : "";
    (void)bin; (void)unused;
    if (!strcmp(name, "vtdec_hw")) g_atomic_int_set(&selected_decoder, 1);
    if (!strcmp(name, "avdec_h264")) g_atomic_int_set(&selected_decoder, 2);
    printf("autoplug=%s\n", name);
}

int main(int argc, char **argv)
{
    if (argc != 2 || (strcmp(argv[1], "--hardware") &&
        strcmp(argv[1], "--software") && strcmp(argv[1], "--mp4"))) {
        fprintf(stderr, "usage: %s --hardware|--software|--mp4\n", argv[0]);
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    alarm(30);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    puts("initializing GStreamer");
    const int software = argc > 1 && !strcmp(argv[1], "--software");
    const int mp4 = argc > 1 && !strcmp(argv[1], "--mp4");
    GstElement *pipeline = NULL, *source = NULL, *sink = NULL, *decode = NULL;
    GError *error = NULL;
    int count = 0, failures = 0;
    gst_init(NULL, NULL);
    if (software) {
        const char *names[] = {"vtdec_hw", "vtdec"};
        for (unsigned i = 0; i < G_N_ELEMENTS(names); ++i) {
            GstPluginFeature *feature = gst_registry_find_feature(gst_registry_get(), names[i], GST_TYPE_ELEMENT_FACTORY);
            if (feature) { gst_plugin_feature_set_rank(feature, GST_RANK_NONE); gst_object_unref(feature); }
        }
    }
    const char *description = mp4 ?
        "appsrc name=source format=time caps=\"video/x-raw,format=NV12,width=64,height=64,framerate=30/1,colorimetry=bt601\" "
        "! vtenc_h264 realtime=true allow-frame-reordering=false ! h264parse "
        "! mp4mux streamable=true fragment-duration=100 ! qtdemux ! h264parse "
        "! decodebin name=decode ! videoconvert ! video/x-raw,format=RGBA ! appsink name=sink sync=false" :
        "appsrc name=source format=time caps=\"video/x-raw,format=NV12,width=64,height=64,framerate=30/1,colorimetry=bt601\" "
        "! vtenc_h264 realtime=true allow-frame-reordering=false ! h264parse "
        "! decodebin name=decode ! videoconvert ! video/x-raw,format=RGBA ! appsink name=sink sync=false";
    pipeline = gst_parse_launch(description, &error);
    if (!pipeline || error) { fprintf(stderr, "pipeline: %s\n", error ? error->message : "null"); return 1; }
    source = gst_bin_get_by_name(GST_BIN(pipeline), "source");
    sink = gst_bin_get_by_name(GST_BIN(pipeline), "sink");
    decode = gst_bin_get_by_name(GST_BIN(pipeline), "decode");
    g_signal_connect(decode, "element-added", G_CALLBACK(element_added), NULL);
    if (gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) { failures++; goto done; }
    for (int i = 0; i < 12; ++i) {
        GstBuffer *buffer = gst_buffer_new_allocate(NULL, 64 * 64 * 3 / 2, NULL);
        GstMapInfo map;
        gst_buffer_map(buffer, &map, GST_MAP_WRITE);
        memset(map.data, 81, 64 * 64);
        for (int j = 64 * 64; j < 64 * 64 * 3 / 2; j += 2) { map.data[j] = 90; map.data[j + 1] = 240; }
        gst_buffer_unmap(buffer, &map);
        GST_BUFFER_PTS(buffer) = i * GST_SECOND / 30;
        GST_BUFFER_DURATION(buffer) = GST_SECOND / 30;
        if (gst_app_src_push_buffer(GST_APP_SRC(source), buffer) != GST_FLOW_OK) { failures++; goto done; }
    }
    gst_app_src_end_of_stream(GST_APP_SRC(source));
    while (count < 13) {
        GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), 5 * GST_SECOND);
        GstVideoInfo info;
        GstVideoFrame frame;
        if (!sample) {
            if (!gst_app_sink_is_eos(GST_APP_SINK(sink))) failures++;
            break;
        }
        if (!gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) ||
            GST_VIDEO_INFO_WIDTH(&info) != 64 || GST_VIDEO_INFO_HEIGHT(&info) != 64 ||
            GST_VIDEO_INFO_FORMAT(&info) != GST_VIDEO_FORMAT_RGBA ||
            !gst_video_frame_map(&frame, &info, gst_sample_get_buffer(sample), GST_MAP_READ)) {
            failures++; gst_sample_unref(sample); break;
        }
        for (int y = 0; y < 64; ++y) {
            const guint8 *row = (const guint8 *)GST_VIDEO_FRAME_PLANE_DATA(&frame, 0) + y * GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
            for (int x = 0; x < 64; ++x) {
                const guint8 *p = row + x * 4;
                if (p[0] < 200 || p[1] > 45 || p[2] > 45 || p[3] != 255) { failures++; goto pixels_done; }
            }
        }
pixels_done:
        gst_video_frame_unmap(&frame);
        gst_sample_unref(sample);
        count++;
    }
    if (count != 12 || g_atomic_int_get(&selected_decoder) != (software ? 2 : 1)) failures++;
done:
    {
        GstBus *bus = gst_element_get_bus(pipeline);
        GstMessage *message;
        while ((message = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR))) {
            gchar *debug = NULL;
            gst_message_parse_error(message, &error, &debug);
            fprintf(stderr, "%s: %s (%s)\n", GST_OBJECT_NAME(message->src), error->message, debug ? debug : "");
            g_clear_error(&error); g_free(debug); gst_message_unref(message); failures++;
        }
        gst_object_unref(bus);
    }
    printf("mode=%s frames=%d decoder=%d failures=%d\n", software ? "software" : mp4 ? "mp4-hardware" : "hardware", count, selected_decoder, failures);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(source); gst_object_unref(sink); gst_object_unref(decode); gst_object_unref(pipeline);
    return failures ? 1 : 0;
}
