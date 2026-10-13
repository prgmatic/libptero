const math = @import("../../math.zig");
const arrayQuaternion = animation.arrayQuaternion;
const std = @import("std");
const animation = @import("../animation.zig");
const Clip = animation.Clip;
const Skeleton = animation.Skeleton;

const Player = @This();

clip: *const Clip,
time: f32 = 0,
speed: f32 = 1,
playing: bool = true,
looping: bool = true,

pub fn seek(self: *Player, time: f32) void {
    self.time = std.math.clamp(time, 0, self.clip.duration);
}

pub fn update(self: *Player, skeleton: *Skeleton, delta: f32) void {
    if (self.playing) {
        self.time += delta * self.speed;
        self.wrap();
    }
    self.apply(skeleton);
}

fn wrap(self: *Player) void {
    if (self.clip.duration <= 0) {
        self.time = 0;
        self.playing = false;
    } else if (self.looping) {
        self.time = math.fast.mod(self.time, self.clip.duration);
    } else if (self.reachedEnd()) {
        self.time = std.math.clamp(self.time, 0, self.clip.duration);
        self.playing = false;
    }
}

fn reachedEnd(self: *const Player) bool {
    return if (self.speed < 0) self.time <= 0 else self.time >= self.clip.duration;
}

pub fn apply(self: *const Player, skeleton: *Skeleton) void {
    for (self.clip.tracks) |track| {
        const value = track.sample(self.time);
        const bone = &skeleton.bones[track.node];
        switch (track.path) {
            .translation => bone.translation = .init(value[0], value[1], value[2]),
            .scale => bone.scale = .init(value[0], value[1], value[2]),
            .rotation => bone.rotation = arrayQuaternion(value).normalized(),
        }
    }
}
