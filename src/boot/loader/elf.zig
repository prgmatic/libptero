const std = @import("std");

pub const ElfHeader32 = extern struct {
    ident: [16]u8 align(1),
    file_type: u16 align(1),
    machine: u16 align(1),
    version: u32 align(1),
    entry_point: u32 align(1),
    program_header_offset: u32 align(1),
    section_header_offset: u32 align(1),
    flags: u32 align(1),
    header_size: u16 align(1),
    program_header_entry_size: u16 align(1),
    program_header_count: u16 align(1),
    section_header_entry_size: u16 align(1),
    section_header_count: u16 align(1),
    section_name_table_index: u16 align(1),
};

pub const ProgramHeader32 = extern struct {
    segment_type: u32,
    offset: u32,
    virtual_address: u32,
    physical_address: u32,
    file_size: u32,
    memory_size: u32,
    flags: u32,
    alignment: u32,
};
