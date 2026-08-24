const Mat4 = @import("mat.zig").Mat4;
const Vec3 = @import("vec.zig").Vec3;
const Vec4 = @import("vec.zig").Vec4;

pub const Frustum = extern struct {
    planes: [6]Vec4,

    pub fn fromMatrix(matrix: *const Mat4) Frustum {
        var result: Frustum = undefined;
        for (0..4) |i| {
            result.planes[0].component(i).* = matrix.m[i][3] + matrix.m[i][0];
            result.planes[1].component(i).* = matrix.m[i][3] - matrix.m[i][0];
            result.planes[2].component(i).* = matrix.m[i][3] + matrix.m[i][1];
            result.planes[3].component(i).* = matrix.m[i][3] - matrix.m[i][1];
            result.planes[4].component(i).* = matrix.m[i][3] + matrix.m[i][2];
            result.planes[5].component(i).* = matrix.m[i][3] - matrix.m[i][2];
        }
        for (&result.planes) |*plane| {
            const length = plane.xyz().length();
            plane.x /= length;
            plane.y /= length;
            plane.z /= length;
            plane.w /= length;
        }
        return result;
    }
    pub fn containsSphere(self: *const Frustum, center: Vec3, radius: f32) bool {
        for (self.planes) |plane| if (plane.xyz().dot(center) + plane.w < -radius) return false;
        return true;
    }
};
