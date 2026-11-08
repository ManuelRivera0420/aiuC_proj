/*
 * Entry point for the bare-metal DOOM build. doomgeneric_Create() calls
 * D_DoomMain(), which runs the engine's own internal game loop forever
 * (calling doomgeneric_Tick()/DG_DrawFrame() each iteration) -- there is
 * nothing for main() to do after that call returns (it shouldn't).
 */
void doomgeneric_Create(int argc, char **argv);

int main(void) {
    doomgeneric_Create(0, (char **)0);
    return 0;
}
