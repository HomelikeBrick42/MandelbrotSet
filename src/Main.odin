package main

import "core:c"
import "core:os"
import "core:fmt"
import "core:math"
import "core:math/big"
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
	scale:         ^big.Rat,
	start_x:       ^big.Rat,
	start_y:       ^big.Rat,
	offset_x:      ^big.Rat,
	offset_y:      ^big.Rat,
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

			cx: big.Rat
			big.rat_set_f64(&cx, (f64(x) / Width * 2.0 - 1.0) * (f64(Width) / f64(Height)))
			big.rat_mul_rat(&cx, &cx, scale)
			big.rat_add_rat(&cx, &cx, offset_x)
			cy: big.Rat
			big.rat_set_f64(&cy, f64(y) / Height * 2.0 - 1.0)
			big.rat_mul_rat(&cy, &cy, scale)
			big.rat_add_rat(&cy, &cy, offset_y)

			MaxIterations :: 1000
			zx: big.Rat
			big.rat_copy(&zx, start_x)
			zy: big.Rat
			big.rat_copy(&zy, start_y)

			i := 0
			for ; i < MaxIterations; i += 1 {
				temp: big.Rat
				temp2: big.Rat

				newZX: big.Rat
				big.rat_mul_rat(&newZX, &zx, &zx)
				big.rat_mul_rat(&temp, &zy, &zy)
				big.rat_sub_rat(&newZX, &newZX, &temp)
				big.rat_add_rat(&newZX, &newZX, &cx)

				newZY: big.Rat
				big.rat_mul_rat(&newZY, &zx, &zy)
				big.rat_mul_rat(&temp, &zx, &zy)
				big.rat_add_rat(&newZY, &newZY, &temp)
				big.rat_add_rat(&newZY, &newZY, &cy)

				defer big.internal_destroy(&temp, &temp2, &newZX, &newZY)

				big.rat_mul_rat(&temp, &newZX, &newZX)
				big.rat_mul_rat(&temp2, &newZY, &newZY)
				big.rat_add_rat(&temp, &temp, &temp2)

				big.rat_set_f64(&temp2, 4.0)

				if comp, _ := big.rat_compare(&temp, &temp2); comp != -1 {
					break
				}
			}

			big.internal_destroy(&cx, &cy, &zx, &zy)

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

	scale: big.Rat
	big.rat_set_f64(&scale, 0.5)

	start_x: big.Rat
	big.rat_set_f64(&start_x, 0.0)
	start_y: big.Rat
	big.rat_set_f64(&start_y, 0.0)

	offset_x: big.Rat
	big.rat_set_f64(&offset_x, 0.0)
	offset_y: big.Rat
	big.rat_set_f64(&offset_y, 0.0)

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
				start_x = &start_y,
				start_y = &start_x,
				offset_x = &offset_x,
				offset_y = &offset_y,
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
						temp: big.Rat
						big.rat_set_f64(&temp, 0.8)
						big.rat_mul_rat(&scale, &scale, &temp)
						big.internal_destroy(&temp)
					} else if event.wheel.y < 0 {
						temp: big.Rat
						big.rat_set_f64(&temp, 0.8)
						big.rat_div_rat(&scale, &scale, &temp)
						big.internal_destroy(&temp)
					}
				}
			}
		}

		time := sdl.GetPerformanceCounter()
		dt := f64(time - last_time) / f64(time_frequency)
		last_time = time

		fmt.println("FPS:", 1.0 / dt)

		if move_state[.Up] {
			temp: big.Rat
			big.rat_set_f64(&temp, dt)
			big.rat_mul_rat(&temp, &scale, &temp)
			big.rat_add_rat(&offset_y, &offset_y, &temp)
			big.internal_destroy(&temp)
		}
		if move_state[.Down] {
			temp: big.Rat
			big.rat_set_f64(&temp, dt)
			big.rat_mul_rat(&temp, &scale, &temp)
			big.rat_sub_rat(&offset_y, &offset_y, &temp)
			big.internal_destroy(&temp)
		}
		if move_state[.Left] {
			temp: big.Rat
			big.rat_set_f64(&temp, dt)
			big.rat_mul_rat(&temp, &scale, &temp)
			big.rat_sub_rat(&offset_x, &offset_x, &temp)
			big.internal_destroy(&temp)
		}
		if move_state[.Right] {
			temp: big.Rat
			big.rat_set_f64(&temp, dt)
			big.rat_mul_rat(&temp, &scale, &temp)
			big.rat_add_rat(&offset_x, &offset_x, &temp)
			big.internal_destroy(&temp)
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
