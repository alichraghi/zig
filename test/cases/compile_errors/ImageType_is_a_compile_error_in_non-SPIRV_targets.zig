comptime {
    _ = @ImageType(.{
        .usage = .storage,
        .format = .unknown,
        .dim = .@"2d",
        .depth = .unknown,
        .arrayed = false,
        .multisampled = false,
        .access = .unknown,
    });
}

// error
// backend=stage2
// target=x86_64-native
//
// :2:21: error: builtin @ImageType is available when targeting SPIR-V; targeted CPU architecture is x86_64
