package main

import "core:c"
import "core:os"
import "core:fmt"
import "core:math"
import "core:math/linalg/glsl"
import "core:intrinsics"
import "core:thread"
import "core:sync"
import "core:sys/windows"

import sdl "vendor:sdl2"

SDL_CheckCode :: proc(code: c.int) {
	if code != 0 {
		fmt.eprintf("SDL Error: %s\n", sdl.GetError())
		intrinsics.trap()
	}
}

SDL_CheckPointer :: proc(pointer: ^$T) -> ^T {
	if pointer == nil {
		fmt.eprintf("SDL Error: %s\n", sdl.GetError())
		intrinsics.trap()
	}
	return pointer
}

Pixel :: distinct [4]u8

MoveKeys :: enum {
	Up,
	Down,
	Left,
	Right,
}

DrawData :: struct {
	pixels:        []Pixel,
	start_index:   int,
	end_index:     int,
	scale:         ^f64,
	start:         ^glsl.dvec2,
	offset:        ^glsl.dvec2,
	start_barrier: ^sync.Barrier,
	end_barrier:   ^sync.Barrier,
}

Draw :: proc(t: ^thread.Thread) {
	using data := cast(^DrawData)t.data
	for {
		sync.barrier_wait(start_barrier)
		for pixel_index := start_index; pixel_index < end_index; pixel_index += 1 {
			x := pixel_index % Width
			y := (len(pixels) - pixel_index - 1) / Width

			c := glsl.dvec2{
				(f64(x) / Width * 2.0 - 1.0) * (f64(Width) / f64(Height)),
				f64(y) / Height * 2.0 - 1.0,
			}
			c *= scale^
			c += offset^

			MaxIterations :: 1000
			z := start^
			i := 0
			for ; i < MaxIterations; i += 1 {
				z = glsl.dvec2{z.x * z.x - z.y * z.y, z.x * z.y + z.x * z.y} + c
				if glsl.dot(z, z) >= 4.0 {
					break
				}
			}

			if i == MaxIterations {
				pixels[pixel_index] = ToPixel({})
			} else {
				pixels[pixel_index] = ToPixel(HueToRGB(f64(i) * 0.01))
			}
		}
		sync.barrier_wait(end_barrier)
	}
}

main :: proc() {
	SDL_CheckCode(sdl.Init(sdl.INIT_EVERYTHING))
	defer sdl.Quit()

	window := SDL_CheckPointer(
		sdl.CreateWindow(
			"Mandelbrot Set",
			sdl.WINDOWPOS_UNDEFINED,
			sdl.WINDOWPOS_UNDEFINED,
			Width,
			Height,
			sdl.WINDOW_SHOWN,
		),
	)
	defer sdl.DestroyWindow(window)

	renderer := SDL_CheckPointer(sdl.CreateRenderer(window, -1, sdl.RENDERER_ACCELERATED))
	defer sdl.DestroyRenderer(renderer)

	texture := SDL_CheckPointer(
		sdl.CreateTexture(
			renderer,
			auto_cast sdl.PixelFormatEnum.RGBA32,
			sdl.TextureAccess.STREAMING,
			Width,
			Height,
		),
	)
	defer sdl.DestroyTexture(texture)

	pixels := make([]Pixel, Width * Height)
	defer delete(pixels)

	scale := 1.5
	start := glsl.dvec2{0.0, 0.0}
	offset := glsl.dvec2{0.0, 0.0}

    thread_count: int = 8
    when ODIN_OS == .Windows {
        system_info: windows.SYSTEM_INFO
        windows.GetSystemInfo(&system_info)
        thread_count = int(system_info.dwNumberOfProcessors)
    }
    fmt.printf("Using %d threads\n", thread_count)

	start_barrier: sync.Barrier
	sync.barrier_init(&start_barrier, thread_count + 1)
	end_barrier: sync.Barrier
	sync.barrier_init(&end_barrier, thread_count + 1)

	for i in 0 ..< thread_count {
		t := thread.create(Draw)
		t.data = new_clone(
			DrawData{
				pixels = pixels,
				start_index = i * (len(pixels) / thread_count),
				end_index = (i + 1) * (len(pixels) / thread_count),
				scale = &scale,
				start = &start,
				offset = &offset,
				start_barrier = &start_barrier,
				end_barrier = &end_barrier,
			},
		)
		thread.start(t)
	}

	move_state: [MoveKeys]bool

	last_time := sdl.GetPerformanceCounter()
	time_frequency := sdl.GetPerformanceFrequency()
	main_loop: for {
		{
			event: sdl.Event
			for sdl.PollEvent(&event) != 0 {
				#partial switch event.type {
				case .QUIT:
					break main_loop
				case .KEYDOWN:
					#partial switch event.key.keysym.sym {
					case sdl.Keycode.W:
						move_state[.Up] = true
					case sdl.Keycode.S:
						move_state[.Down] = true
					case sdl.Keycode.A:
						move_state[.Left] = true
					case sdl.Keycode.D:
						move_state[.Right] = true
					}
				case .KEYUP:
					#partial switch event.key.keysym.sym {
					case sdl.Keycode.W:
						move_state[.Up] = false
					case sdl.Keycode.S:
						move_state[.Down] = false
					case sdl.Keycode.A:
						move_state[.Left] = false
					case sdl.Keycode.D:
						move_state[.Right] = false
					}
				case .MOUSEWHEEL:
					if event.wheel.y > 0 {
						scale *= 0.8
					} else if event.wheel.y < 0 {
						scale /= 0.8
					}
				}
			}
		}

		time := sdl.GetPerformanceCounter()
		dt := f64(time - last_time) / f64(time_frequency)
		last_time = time

		if move_state[.Up] {
			offset.y += scale * dt
		}
		if move_state[.Down] {
			offset.y -= scale * dt
		}
		if move_state[.Left] {
			offset.x -= scale * dt
		}
		if move_state[.Right] {
			offset.x += scale * dt
		}

		sync.barrier_wait(&start_barrier)
		sync.barrier_wait(&end_barrier)

		SDL_CheckCode(sdl.UpdateTexture(texture, nil, raw_data(pixels), Width * 4))
		SDL_CheckCode(sdl.RenderCopy(renderer, texture, nil, nil))
		sdl.RenderPresent(renderer)
	}
}

ToPixel :: proc(color: glsl.dvec3) -> Pixel {
	return {
		u8(clamp(color.r * 255.999, 0.0, 255.0)),
		u8(clamp(color.g * 255.999, 0.0, 255.0)),
		u8(clamp(color.b * 255.999, 0.0, 255.0)),
		255,
	}
}

HueToRGB :: proc(h: f64) -> glsl.dvec3 {
	kr := math.mod(5.0 + h * 6.0, 6.0)
	kg := math.mod(3.0 + h * 6.0, 6.0)
	kb := math.mod(1.0 + h * 6.0, 6.0)

	r := 1.0 - max(min(kr, min(4.0 - kr, 1.0)), 0.0)
	g := 1.0 - max(min(kg, min(4.0 - kg, 1.0)), 0.0)
	b := 1.0 - max(min(kb, min(4.0 - kb, 1.0)), 0.0)

	return {r, g, b}
}

Width :: 640
Height :: 480
