BUILD_DIR := build
include $(N64_INST)/include/n64.mk

all: libdragon-rdp-stars.z64

$(BUILD_DIR)/main.o: CFLAGS += -Os
$(BUILD_DIR)/libdragon-rdp-stars.elf: $(BUILD_DIR)/main.o
libdragon-rdp-stars.z64: N64_ROM_TITLE="Libdragon RDP Stars"

clean:
	rm -rf $(BUILD_DIR) libdragon-rdp-stars.z64

.PHONY: all clean
-include $(wildcard $(BUILD_DIR)/*.d)
