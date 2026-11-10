// SPDX-License-Identifier: BSD-3-Clause
//
// libFuzzer harness for the eq_iir component: the IIR response blob (a "bytes" control, sof_abi_hdr +
// sof_eq_iir_config) goes through the component's set_configuration() and module_prepare(), then audio
// is run through module_process_sink_src(). Built on the same host scaffold as the cmocka test
// test/cmocka/src/audio/eq_iir/eq_iir_process.c (malloc-backed allocator, so ASan sees every block).
//
// Input: byte 0 selects the stream format and channel count, the rest is the blob payload that follows
// the ABI header; the header (magic, size, ABI version) is written correctly by the harness.
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <kernel/header.h>
#include <sof/audio/component_ext.h>
#include <sof/audio/audio_buffer.h>
#include <eq_iir/eq_iir.h>
#include <sof/audio/module_adapter/module/generic.h>
#include <sof/audio/sink_api.h>
#include <sof/audio/source_api.h>
#include <ipc/control.h>
#include <user/eq.h>

#include "util.h"

#define FRAMES		48
#define BUF_MULT	2
#define MAX_CHANNELS	8

static const uint32_t formats[] = {
	SOF_IPC_FRAME_S16_LE, SOF_IPC_FRAME_S24_4LE, SOF_IPC_FRAME_S32_LE,
};

static int send_config(struct processing_module *mod, const uint8_t *payload, size_t size)
{
	const struct module_interface *const ops = mod->dev->drv->adapter_ops;
	size_t cdata_size = sizeof(struct sof_ipc_ctrl_data) + sizeof(struct sof_abi_hdr) + size;
	struct sof_ipc_ctrl_data *cdata = calloc(1, cdata_size);
	int ret;

	if (!cdata)
		return -ENOMEM;

	cdata->cmd = SOF_CTRL_CMD_BINARY;
	cdata->num_elems = size;
	cdata->data[0].magic = SOF_ABI_MAGIC;
	cdata->data[0].type = 0;
	cdata->data[0].size = size;
	cdata->data[0].abi = SOF_ABI_VERSION;
	memcpy(cdata->data[0].data, payload, size);

	ret = ops->set_configuration(mod, 0, MODULE_CFG_FRAGMENT_SINGLE, size,
				     (const uint8_t *)cdata, size, NULL, 0);
	free(cdata);
	return ret;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	static bool initialized;
	struct sof_ipc_comp_process *ipc;
	const struct sof_uuid uuid = SOF_REG_UUID(eq_iir);
	const size_t ipc_size = sizeof(*ipc);
	struct processing_module *mod;
	struct comp_buffer *source, *sink;
	struct sof_source *sources[1];
	struct sof_sink *sinks[1];
	struct comp_dev *dev;
	uint32_t format, channels;
	size_t src_bytes, i;
	int ret;

	if (size < 1 + sizeof(struct sof_eq_iir_config))
		return -1;

	if (!initialized) {
		sys_comp_init(sof_get());
		sys_comp_module_eq_iir_interface_init();
		initialized = true;
	}

	format = formats[data[0] % ARRAY_SIZE(formats)];
	channels = 1 + ((data[0] / ARRAY_SIZE(formats)) % MAX_CHANNELS);
	data++;
	size--;

	ipc = calloc(1, ipc_size + SOF_UUID_SIZE);
	memcpy(ipc + 1, &uuid, SOF_UUID_SIZE);
	ipc->comp.hdr.size = ipc_size + SOF_UUID_SIZE;
	ipc->comp.type = SOF_COMP_MODULE_ADAPTER;
	ipc->config.hdr.size = sizeof(struct sof_ipc_comp_config);
	ipc->size = 0;
	ipc->comp.ext_data_length = SOF_UUID_SIZE;
	dev = comp_new((struct sof_ipc_comp *)ipc);
	free(ipc);
	if (!dev)
		return 0;

	dev->frames = FRAMES;
	mod = comp_mod(dev);

	if (send_config(mod, data, size)) {
		comp_free(dev);
		return 0;
	}

	src_bytes = FRAMES * get_frame_bytes(format, channels);
	mod->priv.mpd.in_buff_size = src_bytes;
	mod->priv.mpd.out_buff_size = src_bytes;
	sink = create_test_sink(dev, 0, format, channels, src_bytes * BUF_MULT);
	source = create_test_source(dev, 0, format, channels, src_bytes * BUF_MULT);

	mod->input_buffers = calloc(1, sizeof(struct input_stream_buffer));
	mod->input_buffers[0].data = &source->stream;
	mod->output_buffers = calloc(1, sizeof(struct output_stream_buffer));
	mod->output_buffers[0].data = &sink->stream;
	mod->stream_params = calloc(1, sizeof(struct sof_ipc_stream_params));
	mod->stream_params->channels = channels;
	mod->period_bytes = get_frame_bytes(format, channels) * 48000 / 1000;

	sources[0] = audio_buffer_get_source(&source->audio_buffer);
	sinks[0] = audio_buffer_get_sink(&sink->audio_buffer);

	ret = module_prepare(mod, sources, 1, sinks, 1);
	if (!ret) {
		/* Stream a full period of non-zero samples through the filter, three times. */
		for (i = 0; i < 3; i++) {
			uint8_t *dst = audio_stream_get_wptr(&source->stream);
			size_t j;

			for (j = 0; j < src_bytes; j++)
				dst[j] = data[(j + i) % size] ^ (uint8_t)(j * 7);
			comp_update_buffer_produce(source, src_bytes);

			mod->input_buffers[0].size = FRAMES;
			mod->input_buffers[0].consumed = 0;
			mod->output_buffers[0].size = 0;
			ret = module_process_sink_src(mod, sources, 1, sinks, 1);
			if (ret)
				break;
			comp_update_buffer_consume(sink, audio_stream_get_avail_bytes(&sink->stream));
		}
	}

	free(mod->input_buffers);
	free(mod->output_buffers);
	free(mod->stream_params);
	mod->stream_params = NULL;
	free_test_source(source);
	free_test_sink(sink);
	comp_free(dev);
	return 0;
}
