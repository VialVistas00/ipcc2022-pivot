CC      ?= gcc
CFLAGS  ?= -O2
LDLIBS  := -lm
BUILD   := build

OMP_NUM_THREADS ?= 4
export OMP_NUM_THREADS

.PHONY: all baseline opt run-baseline run-opt verify flame clean

all: baseline opt

baseline: $(BUILD)/pivot
opt: $(BUILD)/pivot_opt

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/pivot: pivot/pivot.c | $(BUILD)
	$(CC) $(CFLAGS) -Wall -o $@ $< $(LDLIBS)

$(BUILD)/pivot_opt: W04/src/pivot_opt.c | $(BUILD)
	$(CC) $(CFLAGS) -Wall -fopenmp -o $@ $< $(LDLIBS)

run-baseline: baseline
	./$(BUILD)/pivot pivot/uniformvector-2dim-5h.txt

run-opt: opt
	./$(BUILD)/pivot_opt pivot/uniformvector-2dim-5h.txt

verify:
	python W04/scripts/verify_result.py result.txt pivot/refer-2dim-5h.txt

flame:
	python W04/scripts/make_flame_svg.py

clean:
	rm -rf $(BUILD) result.txt
