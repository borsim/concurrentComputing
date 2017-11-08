// COMS20001 - Cellular Automaton Farm - Initial Code Skeleton
// (using the XMOS i2c accelerometer demo code)

#include <platform.h>
#include <xs1.h>
#include <stdio.h>
#include "pgmIO.h"
#include "i2c.h"

#define  IMHT 16                  //image height
#define  IMWD 16                  //image width
#define  PROCESS_THREAD_COUNT 4
#define  ROWS_PER_THREAD 4

typedef unsigned char uchar;      //using uchar as shorthand

port p_scl = XS1_PORT_1E;         //interface ports to orientation
port p_sda = XS1_PORT_1F;

#define FXOS8700EQ_I2C_ADDR 0x1E  //register addresses for orientation
#define FXOS8700EQ_XYZ_DATA_CFG_REG 0x0E
#define FXOS8700EQ_CTRL_REG_1 0x2A
#define FXOS8700EQ_DR_STATUS 0x0
#define FXOS8700EQ_OUT_X_MSB 0x1
#define FXOS8700EQ_OUT_X_LSB 0x2
#define FXOS8700EQ_OUT_Y_MSB 0x3
#define FXOS8700EQ_OUT_Y_LSB 0x4
#define FXOS8700EQ_OUT_Z_MSB 0x5
#define FXOS8700EQ_OUT_Z_LSB 0x6


void processGame(char workerID, chanend fromDistributor, chanend topChannel, chanend bottomChannel);
unsigned int parseRowToInt(int rowNumber);
unsigned int generateNewRow(unsigned int top, unsigned int self, unsigned int bottom, int length);
/////////////////////////////////////////////////////////////////////////////////////////
//
// Read Image from PGM file from path infname[] to channel c_out
//
/////////////////////////////////////////////////////////////////////////////////////////
void DataInStream(char infname[], chanend c_out)
{
  int res;
  uchar line[ IMWD ];
  printf( "DataInStream: Start...\n" );

  //Open PGM file
  res = _openinpgm( infname, IMWD, IMHT );
  if( res ) {
    printf( "DataInStream: Error openening %s\n.", infname );
    return;
  }

  //Read image line-by-line and send byte by byte to channel c_out
  for( int y = 0; y < IMHT; y++ ) {
    _readinline( line, IMWD );
    for( int x = 0; x < IMWD; x++ ) {
      c_out <: line[ x ];
      printf( "-%4.1d ", line[ x ] ); //show image values
    }
    printf( "\n" );
  }

  //Close PGM image file
  _closeinpgm();
  printf( "DataInStream: Done...\n" );
  return;
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Start your implementation by changing this function to implement the game of life
// by farming out parts of the image to worker threads who implement it...
// Currently the function just inverts the image
//
/////////////////////////////////////////////////////////////////////////////////////////
void distributor(chanend c_in, chanend c_out, chanend fromAcc)
{
  uchar val;
  //Starting up and wait for tilting of the xCore-200 Explorer
  printf( "ProcessImage: Start, size = %dx%d\n", IMHT, IMWD );
  //printf( "Waiting for Board Tilt...\n" );
  //fromAcc :> int value;

  printf( "Processing...\n" );

  chan rowChannels[PROCESS_THREAD_COUNT];
  chan distributorChannels[PROCESS_THREAD_COUNT];
  par {
      par (int i = 0; i < PROCESS_THREAD_COUNT; i++) {
            processGame(i, distributorChannels[i], rowChannels[i],rowChannels[(i+1)%PROCESS_THREAD_COUNT]);
      }
      for (int j = 0; j < PROCESS_THREAD_COUNT; j++) {
          for (int k = 0; k < ROWS_PER_THREAD; k++) {
              unsigned int currentRow = 0;
              for( int x = 0; x < IMWD; x++ ) {                    // Go through each pixel per line
                  c_in :> val;                                   // Read the pixel value
                  if (val == 0xFF) currentRow = currentRow | 1;  // Put pixel on the end of the int
                  currentRow = currentRow << 1;                  // Shift int to the left
              }
              distributorChannels[j] <: currentRow;
          }
      }
  }
  //TODO we're not going to get feedback from here
  // NOTE: This won't work. Worker tasks all need to finish in the par() block for this to happen
  // Start waiting for feedback from workers
    for (int j = 0; j < PROCESS_THREAD_COUNT; j++) {
        for (int k = 0; k < ROWS_PER_THREAD; k++) {
            unsigned int currentRow = 0;
            distributorChannels[j] :> currentRow;
            for( int x = 0; x < IMWD; x++ ) {
                char pixelVal = 0;
                char bitVal = (currentRow & (1 << (IMWD-1))) >> (IMWD-1); // Check pixel at the start (most significant part) of the int
                if (bitVal == 1) val = 0xFF;                            // Convert bit value to pixel value
                currentRow = currentRow << 1;                           // Shift int to the left
                c_out :> pixelVal;                                      // Print pixel to outstream
            }
        }
    }
}
void processGame(char workerID, chanend fromDistributor, chanend topChannel, chanend bottomChannel) {
    unsigned int oldRowData[ROWS_PER_THREAD + 2];
    unsigned int newRowData[ROWS_PER_THREAD + 2];
    for (int j = 1; j <= ROWS_PER_THREAD; j++) {
        fromDistributor :> oldRowData[j];
    }
    while(1) {
        if (workerID % 2 == 0) {
            // Even-numbered channels send data upwards then downwards to odd-numbered channels
            // This means that odd-numbered channels receive first from the bottom then the top
            topChannel    <: oldRowData[1];
            bottomChannel <: oldRowData[ROWS_PER_THREAD];
            // Then they receive from the bottom first then top
            bottomChannel :> oldRowData[ROWS_PER_THREAD + 1];
            topChannel    :> oldRowData[0];
        } else {
            // Odd-numbered channels receive data from the bottom, then the top
            bottomChannel :> oldRowData[ROWS_PER_THREAD + 1];
            topChannel    :> oldRowData[0];
            // Then they take their round transmitting towards the top, then the bottom
            topChannel    <: oldRowData[1];
            bottomChannel <: oldRowData[ROWS_PER_THREAD];
        }
        for (int k = 1; k <= ROWS_PER_THREAD; k++) {
            newRowData[k] = generateNewRow(oldRowData[k-1],oldRowData[k],oldRowData[k+1],IMWD);
        }
        for (int l = 1; l <= ROWS_PER_THREAD; l++) {
            oldRowData[l] = newRowData[l];
            printf("New row %d\n", newRowData[l]);
        }
    }
    // When we do limited iterations this will give the result data back to the distributor
    for (int j = 1; j <= ROWS_PER_THREAD; j++) {
            fromDistributor <: oldRowData[j];
    }
}
// Circular left shift the bits in an int value that uses 'size' number of bits
unsigned int circularLeftShift(unsigned int input, int length) {
    unsigned int result = input << 1 | input >> (length-1);
    // Mask to unneeded values
    unsigned int mask = 0xFFFFFFFF >> (32-length);
    result = result & mask;
    return result;
}
// Circular right shift the bits in an int value that uses 'size' number of bits
unsigned int circularRightShift(unsigned int input, int length) {
    unsigned int result = input >> 1 | input << (length-1);
    // Mask unneeded values
    unsigned int mask = 0xFFFFFFFF >> (32-length);
    result = result & mask;
    return result;
}
char determineLifeState(unsigned int currentState, char counter) {
    char resultState = 0;
    if (currentState == 0 && counter == 3)     resultState = 1; // Dead with 3 neighbours becomes alive
    else if (currentState == 1 && counter < 2) resultState = 0; // Living with <2 neighbours dies
    else if (currentState == 1 && counter > 3) resultState = 0; // Living with 3> neighbours dies
    else if (currentState == 1)                resultState = 1; // Living with 2/3 neighbours lives
    else                                       resultState = 0; // Dead anything else stays dead
    return resultState;
}
void addToRow(char* original, unsigned int added, int length) {
    unsigned int addedCopy = added;
    for (int i = 0; i < length; i++) {
        // Take the least significant bit (from the rightmost side) and add to row
        original[i] += addedCopy & 1;
        // Shift it to the right to delete the least significant bit
        addedCopy = addedCopy >> 1;
    }
}
void addThreeRows(char* original, unsigned int added, int length) {
    unsigned int leftShifted = circularLeftShift(added, length);
    unsigned int rightShifted = circularRightShift(added, length);
    addToRow(original, leftShifted, length);
    addToRow(original, added, length);
    addToRow(original, rightShifted, length);
}
unsigned int generateNewRow(unsigned int top, unsigned int self, unsigned int bottom, int length) {
    unsigned int newRow = 0;
    unsigned int selfCopy = self;
    // Initialize new counter array for determining tile states
    char newRowCount[32];
    for (int i = 0; i < length; i++) newRowCount[i] = 0;
    // Add right side neighbours' states
    addToRow(newRowCount, circularLeftShift(selfCopy, length), length);
    // Add left side neighbours' states
    addToRow(newRowCount, circularRightShift(selfCopy, length), length);
    // Add top and top diagonals states
    addThreeRows(newRowCount, top, length);
    // Add bottom and bottom diagonals states
    addThreeRows(newRowCount, bottom, length);
    // Once all the neighbours have been counted, proceed to determining life states

    for (int j = 0; j < length; j++) {
        // Get most significant bit (on the leftmost side)
        unsigned int currentState = (selfCopy & (1 << (length-1))) >> (length-1);
        // Determine whether tile is alive or not
        char result = determineLifeState(currentState, newRowCount[length-j-1]);
        // If the result is alive, put a 1 on the least significant bit (the shift below will make it more significant)
        if (result == 1) newRow = newRow | 1;
        // Store the new value by shifting the result left
        if (j != length-1) newRow = newRow << 1;
        // Expose a new value at the most significant place by shifting the original's copy left
        selfCopy = selfCopy << 1;
    }
    return newRow;
}

int assertEqual(int first, int second, int testNum) {
    if (first == second) {
        //printf("TEST %d SUCCESSFUL\n", testNum);
        return 1;
    }
    else {
        printf("TEST %d FAILED. Expected: %d, got: %d\n", testNum, first, second);
        return 0;
    }
}
void runTests() {
    //BIT SHIFTING
    int bitTestTotal = 0;

    //Two commented out tests fail, they are ints which are larger than 32 bit
    //This ultimately is a flaw in the int type, not our code
    //So not sure how big a problem this is, as length is set by IMWD
    bitTestTotal += assertEqual(2, circularLeftShift(1, 32), 1);
    bitTestTotal += assertEqual(1, circularLeftShift(4, 3), 2);
    bitTestTotal += assertEqual(3, circularLeftShift(9, 4), 3);
    bitTestTotal += assertEqual(3, circularLeftShift(2147483649, 32), 4);
    //bitTesTtotal += assertEqual(3, circularLeftShift(4294967297, 33), 5);
    bitTestTotal += assertEqual(1, circularRightShift(2, 4), 6);
    bitTestTotal += assertEqual(8, circularRightShift(1, 4), 7);
    bitTestTotal += assertEqual(12, circularRightShift(9, 4), 8);
    bitTestTotal += assertEqual(3221225472, circularRightShift(2147483649, 32), 9);
    //tesTtotal += assertEqual(6442450944, circularRightShift(4294967297, 33), 10);

    if (bitTestTotal == 8) printf("All bit shifting tests pass.\n");


    //DETERMINE LIVE STATE
    int lifeTestTotal = 0;

    lifeTestTotal += assertEqual(0 ,determineLifeState(1,0) , 11);
    lifeTestTotal += assertEqual(0 ,determineLifeState(1,1) , 12);
    lifeTestTotal += assertEqual(1 ,determineLifeState(1,2) , 13);
    lifeTestTotal += assertEqual(1 ,determineLifeState(1,3) , 14);
    lifeTestTotal += assertEqual(0 ,determineLifeState(1,4) , 15);
    lifeTestTotal += assertEqual(0 ,determineLifeState(1,8) , 16);
    lifeTestTotal += assertEqual(0 ,determineLifeState(1,9) , 17);
    lifeTestTotal += assertEqual(1 ,determineLifeState(0,3) , 18);
    lifeTestTotal += assertEqual(0 ,determineLifeState(0,4) , 19);
    lifeTestTotal += assertEqual(0 ,determineLifeState(0,2) , 20);

    if (lifeTestTotal == 10) printf("All life state tests pass.\n");



    //ADD TO ROW
    int addTestTotal = 0;
    char testCount[16] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    addToRow(testCount, 5, 16);

    addTestTotal += assertEqual(1 ,testCount[0] , 21);
    addTestTotal += assertEqual(0 ,testCount[1] , 22);
    addTestTotal += assertEqual(1 ,testCount[2] , 23);

    char testCount2[32] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    addToRow(testCount2, 2147483649, 32);

    addTestTotal += assertEqual(1 ,testCount2[0] , 24);
    addTestTotal += assertEqual(1 ,testCount2[31] , 25);

    if (addTestTotal == 5) printf("All add to row tests pass.\n");


    //ADD THREE ROWS
    int add3TestTotal = 0;
    char test3Count[16] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
    addThreeRows(test3Count, 32769, 16);

    add3TestTotal += assertEqual(2, test3Count[0], 26);
    add3TestTotal += assertEqual(2, test3Count[15], 27);
    add3TestTotal += assertEqual(1, test3Count[14], 28);
    add3TestTotal += assertEqual(1, test3Count[1], 29);

    char test3Count2[32] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0};
        addThreeRows(test3Count2, 2147483649, 32);

        add3TestTotal += assertEqual(2, test3Count2[0], 30);
        add3TestTotal += assertEqual(2, test3Count2[31], 31);
        add3TestTotal += assertEqual(1, test3Count2[30], 32);
        add3TestTotal += assertEqual(1, test3Count2[1], 33);

    if (add3TestTotal == 8) printf("All add three rows tests pass.\n");


    //GENERATE ROW
    int genTestTotal = 0;


    //square
    genTestTotal += assertEqual(0, generateNewRow(0,0,3,8), 34);
    genTestTotal += assertEqual(3, generateNewRow(3,3,0,8), 35);
    genTestTotal += assertEqual(3, generateNewRow(0,3,3,8), 36);
    genTestTotal += assertEqual(0, generateNewRow(3,0,0,8), 37);

    //beehive
    genTestTotal += assertEqual(0, generateNewRow(0,0,24,8), 38);
    genTestTotal += assertEqual(24, generateNewRow(0,24,36,8), 38);
    genTestTotal += assertEqual(36, generateNewRow(24,36,24,8), 39);
    genTestTotal += assertEqual(24, generateNewRow(36,24,0,8), 40);
    genTestTotal += assertEqual(0, generateNewRow(24,0,0,8), 41);

    //blinker
    genTestTotal += assertEqual(0, generateNewRow(0,0,0,6), 42);
    genTestTotal += assertEqual(4, generateNewRow(0,0,14,6), 43);
    genTestTotal += assertEqual(4, generateNewRow(0,14,0,6), 44);
    genTestTotal += assertEqual(4, generateNewRow(14,0,0,6), 45);
    genTestTotal += assertEqual(0, generateNewRow(0,0,0,6), 46);

    if (genTestTotal == 14) printf("All generate row tests pass.\n");
}
/////////////////////////////////////////////////////////////////////////////////////////
//
// Write pixel stream from channel c_in to PGM image file
//
/////////////////////////////////////////////////////////////////////////////////////////
void DataOutStream(char outfname[], chanend c_in)
{
  int res;
  uchar line[ IMWD ];

  //Open PGM file
  printf( "DataOutStream: Start...\n" );
  res = _openoutpgm( outfname, IMWD, IMHT );
  if( res ) {
    printf( "DataOutStream: Error opening %s\n.", outfname );
    return;
  }

  //Compile each line of the image and write the image line-by-line
  for( int y = 0; y < IMHT; y++ ) {
    for( int x = 0; x < IMWD; x++ ) {
      c_in :> line[ x ];
    }
    _writeoutline( line, IMWD );
    printf( "DataOutStream: Line written...\n" );
  }

  //Close the PGM image
  _closeoutpgm();
  printf( "DataOutStream: Done...\n" );
  return;
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Initialise and  read orientation, send first tilt event to channel
//
/////////////////////////////////////////////////////////////////////////////////////////
void orientation( client interface i2c_master_if i2c, chanend toDist) {
  i2c_regop_res_t result;
  char status_data = 0;
  int tilted = 0;

  // Configure FXOS8700EQ
  result = i2c.write_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_XYZ_DATA_CFG_REG, 0x01);
  if (result != I2C_REGOP_SUCCESS) {
    printf("I2C write reg failed\n");
  }
  
  // Enable FXOS8700EQ
  result = i2c.write_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_CTRL_REG_1, 0x01);
  if (result != I2C_REGOP_SUCCESS) {
    printf("I2C write reg failed\n");
  }

  //Probe the orientation x-axis forever
  while (1) {

    //check until new orientation data is available
    do {
      status_data = i2c.read_reg(FXOS8700EQ_I2C_ADDR, FXOS8700EQ_DR_STATUS, result);
    } while (!status_data & 0x08);

    //get new x-axis tilt value
    int x = read_acceleration(i2c, FXOS8700EQ_OUT_X_MSB);

    //send signal to distributor after first tilt
    if (!tilted) {
      if (x>30) {
        tilted = 1 - tilted;
        toDist <: 1;
      }
    }
  }
}

/////////////////////////////////////////////////////////////////////////////////////////
//
// Orchestrate concurrent system and start up all threads
//
/////////////////////////////////////////////////////////////////////////////////////////
int main(void) {

i2c_master_if i2c[1];               //interface to orientation
///////////////////////////////////////////////////////////////////////////////////////////////////////////
runTests();   //TESTS
///////////////////////////////////////////////////////////////////////////////////////////////////////////
char infname[] = "test.pgm";     //put your input image path here
char outfname[] = "testout.pgm"; //put your output image path here
chan c_inIO, c_outIO, c_control;    //extend your channel definitions here

par {
    i2c_master(i2c, 1, p_scl, p_sda, 10);   //server thread providing orientation data
    orientation(i2c[0],c_control);        //client thread reading orientation data
    DataInStream(infname, c_inIO);          //thread to read in a PGM image
    DataOutStream(outfname, c_outIO);       //thread to write out a PGM image
    distributor(c_inIO, c_outIO, c_control);//thread to coordinate work on image
  }

  return 0;
}
